import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocsMigrationTests {
  static var fixture: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Fixtures/storage-v4.db")
  }

  static func copyFixture(to home: URL) throws -> DatabaseStore {
    try FileManager.default.copyItem(at: fixture, to: home.appending(path: "silta.db"))
    return StorageSchemaTests.store(home)
  }

  @Test func fixtureIsFrozenAtV4() throws {
    var config = Configuration()
    config.readonly = true
    let queue = try DatabaseQueue(path: Self.fixture.path, configuration: config)
    try queue.read { (db: Database) throws in
      #expect(
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
          == ["v1", "v2", "v3", "v4"])
      #expect(
        try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'") == 4)
      #expect(!(try db.columns(in: "doc_rev")).contains { $0.name == "about_refs" })
      #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
    }
  }

  @Test func backfillsOnlyKnownCurrentMetadataAndPreservesHistory() throws {
    try withScratchDirectory { home in
      let store = try Self.copyFixture(to: home)
      let before = try identities(in: store)
      try store.initialize()
      let columns = try store.read { Set(try $0.columns(in: "doc_rev").map(\.name)) }
      try #require(Set(["title", "kind", "about_refs", "source_task_id"]).isSubset(of: columns))
      try store.read { (db: Database) throws in
        let current = try #require(try Row.fetchOne(db, sql: "SELECT * FROM doc_rev WHERE id=12"))
        #expect(current["title"] as String? == "Push rules")
        #expect(current["kind"] as String? == "contract")
        let about = try #require(current["about_refs"] as String?)
        #expect(
          try JSONDecoder().decode([String].self, from: Data(about.utf8)) == [
            "app:mobile", "edge:mobile/api/http-api", "service:push",
          ])
        for id in [11, 13] {
          let revision = try #require(
            try Row.fetchOne(db, sql: "SELECT * FROM doc_rev WHERE id=?", arguments: [id]))
          #expect(revision["title"] as String? == nil)
          #expect(revision["kind"] as String? == nil)
          #expect(revision["about_refs"] as String? == nil)
        }
        #expect(current["body_md"] as String == "Keep unknown categories visible.")
        #expect(current["future"] as String == "retained current")
        #expect(current["source_task_id"] as Int64? == nil)
        #expect(
          try String.fetchOne(db, sql: "SELECT future FROM doc_rev WHERE id=11")
            == "retained history")
        #expect(try String.fetchOne(db, sql: "SELECT settings FROM workspace") == "{\"future\":42}")
        #expect(
          try String.fetchOne(db, sql: "SELECT verified_at FROM doc") == "2023-11-14T22:13:20.000Z")
        #expect(
          try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'") ?? 0
            >= 5)
        try #require(try db.tableExists("doc_verification"))
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_verification") == 0)
      }
      #expect(try identities(in: store) == before)
      let backups = try FileManager.default.contentsOfDirectory(
        atPath: home.appending(path: "backups").path)
      #expect(backups == ["silta-2023-11-14-before-v5-1700000000000.db"])
      try StorageSchemaTests.store(home).initialize()
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: home.appending(path: "backups").path)
          == backups)
    }
  }

  @Test func verificationAndSourceTaskUseOwnedForeignKeys() throws {
    try withScratchDirectory { home in
      let store = try Self.copyFixture(to: home)
      try store.initialize()
      try #require(try store.read { try $0.tableExists("doc_verification") })
      try store.write { tx in
        let db = tx.database
        try db.execute(
          sql: """
            INSERT INTO doc_verification(uid,doc_rev_id,actor,message,app_shas,created_at)
            VALUES('01HF7YAT00ZZZZZZZZZZZZZ030',12,'human:acme','Checked rule','[]',
              '2023-11-14T22:13:20.000Z')
            """)
        #expect(throws: DatabaseError.self) {
          try db.execute(sql: "UPDATE doc_verification SET doc_rev_id=999")
        }
        try db.execute(sql: "UPDATE doc_rev SET source_task_id=1 WHERE id=12")
        #expect(throws: DatabaseError.self) {
          try db.execute(sql: "UPDATE doc_rev SET source_task_id=999 WHERE id=12")
        }
      }
    }
  }

  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func actualPriorWriterRefusesUpgradedDatabaseWithoutChangingIt() throws {
    let binary = try #require(ProcessInfo.processInfo.environment["SILTA_PRIOR_BINARY"])
    try withScratchDirectory { home in
      let store = try Self.copyFixture(to: home)
      let environment = ["SILTA_HOME": home.path, "SILTA_ACTOR": "agent:codex:acme"]
      let before = try SiltaBinary.runProcess(
        URL(filePath: binary), ["--ws", "acme", "task", "add", "Before upgrade"],
        in: home, environment: environment)
      try #require(before.termination == .exit(0))
      try store.initialize()
      let identities = try identities(in: store)
      let after = try SiltaBinary.runProcess(
        URL(filePath: binary), ["--json", "--ws", "acme", "task", "add", "After upgrade"],
        in: home, environment: environment)
      #expect(after.termination == .exit(9))
      #expect(after.stdout.contains("Database requires a newer version of silta."))
      #expect(try self.identities(in: store) == identities)
    }
  }

  private func identities(in store: DatabaseStore) throws -> [[String]] {
    try store.read { db in
      try [
        "workspace", "repo", "app", "service", "edge", "topic", "task", "doc", "doc_rev", "link",
      ].map {
        try String.fetchAll(db, sql: "SELECT id || ':' || uid FROM \($0) ORDER BY id")
      }
    }
  }
}
