import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocAuditMigrationTests {
  static var fixture: URL {
    DocsMigrationTests.fixture.deletingLastPathComponent().appending(path: "storage-v6.db")
  }

  static func copy(_ fixture: URL, to home: URL) throws -> DatabaseStore {
    try FileManager.default.copyItem(at: fixture, to: home.appending(path: "silta.db"))
    return StorageSchemaTests.store(home)
  }

  static func columns(_ path: String, table: String) throws -> [String] {
    try DatabaseQueue(path: path).read { try $0.columns(in: table).map(\.name) }
  }

  static func rows(_ path: String, table: String, columns: [String]) throws -> [String] {
    let names = columns.map { "\"" + $0 + "\"" }.joined(separator: ",")
    return try DatabaseQueue(path: path).read {
      try Row.fetchAll($0, sql: "SELECT \(names) FROM \(table) ORDER BY rowid").map(\.description)
    }
  }

  @Test func fixtureIsGenuineV6WithAllLegacyStates() throws {
    try DatabaseQueue(path: Self.fixture.path).read { (db: Database) throws in
      #expect(
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
          == ["v1", "v2", "v3", "v4", "v5", "v6"])
      #expect(
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'") == "6"
      )
      #expect(
        Set(try String.fetchAll(db, sql: "SELECT state FROM doc_rev"))
          == ["accepted", "proposed", "rejected", "superseded"])
      #expect(!(try db.columns(in: "doc_rev")).contains { $0.name == "triaged_at" })
      #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
    }
  }

  @Test(arguments: [4, 6]) func preservesLegacyDataWithoutInventingDecisions(version: Int) throws {
    try withScratchDirectory { home in
      let source = version == 4 ? DocsMigrationTests.fixture : Self.fixture
      let store = try Self.copy(source, to: home)
      var tables = ["doc", "doc_rev", "link", "comment", "seq_counter", "task", "workspace"]
      if version == 6 { tables.append("doc_verification") }
      let columns = try tables.map { try Self.columns(store.path, table: $0) }
      let before = try zip(tables, columns).map {
        try Self.rows(store.path, table: $0, columns: $1)
      }
      try store.initialize()
      try #require(
        try store.read {
          Set(try $0.columns(in: "doc_rev").map(\.name)).isSuperset(of: [
            "triaged_at", "triaged_by",
          ])
        })
      #expect(
        try store.read {
          try Int.fetchOne(
            $0,
            sql:
              "SELECT count(*) FROM doc_rev WHERE triaged_at IS NOT NULL OR triaged_by IS NOT NULL")
        } == 0)
      #expect(
        try zip(tables, columns).map { try Self.rows(store.path, table: $0, columns: $1) } == before
      )
      let backups = try FileManager.default.contentsOfDirectory(
        atPath: home.appending(path: "backups").path)
      if version == 6 {
        #expect(backups == ["silta-2023-11-14-before-v7-1700000000000.db"])
        let backup = home.appending(path: "backups").appending(path: try #require(backups.first))
        #expect(!(try Self.columns(backup.path, table: "doc_rev")).contains("triaged_at"))
        #expect(
          try zip(tables, columns).map { try Self.rows(backup.path, table: $0, columns: $1) }
            == before)
      }
      try StorageSchemaTests.store(home).initialize()
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: home.appending(path: "backups").path)
          == backups)
    }
  }

  @Test func directEditsPreserveDecisionEvidenceAndDoNotCreateIt() throws {
    try withScratchDirectory { home in
      let store = try Self.copy(Self.fixture, to: home)
      try store.initialize()
      try Self.seedDecision(store)
      let before = try Self.auditRows(store)
      let revision = try DocStoreTests.accept(
        DocDraft(slug: "push-rules", body: "A direct rule"),
        in: store, ids: SeededIDGenerator(seed: 80))
      #expect(revision.revision == 10)
      #expect(try Self.auditRows(store).prefix(before.count).elementsEqual(before))
      #expect(
        try store.read {
          try Int.fetchOne(
            $0,
            sql:
              """
              SELECT count(*) FROM doc_rev WHERE rev=10
              AND triaged_at IS NULL AND triaged_by IS NULL
              """
          )
        } == 1)
    }
  }

  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func actualV6WriterKeepsPopulatedAuditFields() throws {
    let binary = try #require(ProcessInfo.processInfo.environment["SILTA_V6_BINARY"])
    try withScratchDirectory { home in
      let store = try Self.copy(Self.fixture, to: home)
      try store.initialize()
      try Self.seedDecision(store)
      let before = try Self.auditRows(store)
      let result = try SiltaBinary.runProcess(
        URL(filePath: binary),
        ["--ws", "acme", "task", "add", "Coexist with document decisions"], in: home,
        environment: [
          "SILTA_HOME": home.path, "SILTA_ACTOR": "agent:codex:acme",
          "SILTA_NOW": "2023-11-14T22:13:21.000Z", "SILTA_ID_SEED": "72",
        ])
      #expect(result.termination == .exit(0))
      #expect(try Self.auditRows(store) == before)
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
        } == "6")
      #expect(
        try store.read {
          try Int.fetchOne(
            $0, sql: "SELECT count(*) FROM task WHERE title='Coexist with document decisions'")
        } == 1)
    }
  }

  static func seedDecision(_ store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql:
          "UPDATE doc_rev SET triaged_at=?,triaged_by=? WHERE id=14",
        arguments: ["2023-11-14T22:14:00.000Z", "human:acme"]
      )
    }
  }

  static func auditRows(_ store: DatabaseStore) throws -> [String] {
    try store.read {
      try Row.fetchAll(
        $0, sql: "SELECT id,uid,triaged_at,triaged_by,future FROM doc_rev ORDER BY id"
      ).map(\.description)
    }
  }
}
