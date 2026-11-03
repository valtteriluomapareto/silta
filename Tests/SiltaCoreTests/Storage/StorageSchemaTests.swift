import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StorageSchemaTests {
  static let instant = Date(timeIntervalSince1970: 1_700_000_000)

  static func store(_ home: URL) -> DatabaseStore {
    DatabaseStore(home: home, clock: FakeClock(now: instant), jitter: { 0 })
  }

  @Test func constructionAndMissingReadNeverInitialize() async throws {
    try await withScratchDirectory { scratch in
      let home = scratch.appending(path: "data")
      let store = Self.store(home)
      #expect(!FileManager.default.fileExists(atPath: home.path))
      #expect(throws: StorageError.unavailable) { try store.read { _ in () } }
      #expect(!FileManager.default.fileExists(atPath: home.path))
      #expect(throws: StorageError.unavailable) { try Self.store(scratch).read { _ in () } }
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "silta.db").path))
      let environment = try await SiltaEnvironment.system(
        environment: ["SILTA_HOME": home.path], userHome: scratch)
      #expect(environment.db.path == home.appending(path: "silta.db").path)
      #expect(!FileManager.default.fileExists(atPath: home.path))
    }
  }

  @Test func completeSchemaAndPragmasSurviveReopen() throws {
    try withScratchDirectory { scratch in
      let store = Self.store(scratch)
      try store.initialize()
      let expected: Set<String> = [
        "meta", "workspace", "repo", "repo_path", "app", "environment", "service", "edge",
        "topic", "topic_alias", "seq_counter", "task", "task_plan_rev", "task_event", "comment",
        "review_request", "doc", "doc_rev", "link", "alias_decision", "source", "worktree_override",
        "change_log", "grdb_migrations",
      ]
      try store.read { db in
        let actual = try String.fetchAll(
          db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        #expect(Set(actual) == expected)
        #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
        #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1)
        #expect(try Int.fetchOne(db, sql: "PRAGMA busy_timeout") == 5000)
        #expect(
          try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
            == "1")
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(task)").map {
          $0["name"] as String
        }
        #expect(
          columns == [
            "id", "uid", "workspace_id", "seq", "title", "type", "status", "priority",
            "description_md", "plan_md", "plan_rev", "acceptance_md", "result_md", "parent_id",
            "app_id", "claimed_by", "claimed_at", "branch", "worktree", "done_sha", "done_branch",
            "done_dirty", "archive_override", "external_ref", "created_by", "created_at",
            "updated_at", "closed_at",
          ])
      }
      let backups = try FileManager.default.contentsOfDirectory(
        atPath: scratch.appending(path: "backups").path)
      #expect(backups.count == 1)
      #expect(backups == ["silta-2023-11-14-before-v1-1700000000000.db"])
      let initial = try DatabaseQueue(
        path: scratch.appending(path: "backups").appending(path: backups[0]).path)
      try initial.read { db in
        let tables = try Int.fetchOne(
          db, sql: "SELECT count(*) FROM sqlite_master WHERE type='table'")
        let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
        #expect(tables == 0)
        #expect(integrity == "ok")
      }
      try Self.store(scratch).initialize()
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: scratch.appending(path: "backups").path)
          == backups)
    }
  }

  @Test func workspaceRecordsRoundTripAndReadOnlyAccess() throws {
    try withScratchDirectory { scratch in
      let store = Self.store(scratch)
      try store.initialize()
      let queue = try DatabaseQueue(path: store.path)
      try queue.write { db in
        var workspace = Workspace(
          uid: "acme-workspace", slug: "acme", name: "Acme", taskPrefix: "AC")
        try workspace.insert(db)
        #expect(try Workspace.fetchOne(db) == workspace)
        var duplicate = Workspace(
          uid: "acme-duplicate", slug: "acme", name: "Acme", taskPrefix: "OTHER")
        #expect(throws: DatabaseError.self) { try duplicate.insert(db) }
      }
      #expect(throws: StorageError.unavailable) {
        try store.read { db in try db.execute(sql: "DELETE FROM workspace") }
      }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 1)
    }
  }

  @Test func schemaConstraintsRejectInvalidRows() throws {
    try withScratchDirectory { scratch in
      let store = Self.store(scratch)
      try store.initialize()
      let queue = try DatabaseQueue(path: store.path)
      try queue.write { db in
        var workspace = Workspace(uid: "acme", slug: "acme", name: "Acme", taskPrefix: "AC")
        try workspace.insert(db)
        try db.execute(
          sql: "INSERT INTO repo(uid,workspace_id,slug) VALUES('acme-repo',1,'platform')")
        try db.execute(
          sql:
            """
            INSERT INTO app(uid, workspace_id, slug, name, repo_id, ref) VALUES('acme-app', 1,
            'platform', 'Acme', 1, 'main')
            """
        )
        #expect(throws: DatabaseError.self) {
          try db.execute(
            sql:
              """
              INSERT INTO app(uid, workspace_id, slug, name, repo_id, ref)
              VALUES('acme-second-app', 1, 'secondary', 'Acme', 1, 'main')
              """
          )
        }
        #expect(throws: DatabaseError.self) {
          try db.execute(
            sql: "INSERT INTO repo(uid,workspace_id,slug) VALUES('acme-orphan',999,'missing')")
        }
        #expect(throws: DatabaseError.self) {
          try db.execute(
            sql:
              """
              INSERT INTO comment(uid, seq, kind, body_md, actor, created_at)
              VALUES('acme-comment', 1, 'comment', '', 'agent:unknown:acme',
              '2023-11-14T22:13:20.000Z')
              """
          )
        }
        #expect(throws: DatabaseError.self) {
          try db.execute(
            sql:
              """
              INSERT INTO edge(uid, workspace_id, from_app_id, kind, summary)
              VALUES('acme-edge', 1, 1, 'http', 'Acme')
              """
          )
        }
      }
    }
  }

  // One write gate (D32): a newer schema refuses older writers only when its
  // migration raised min_writer_version. Either way it is never migrated.
  @Test(arguments: [false, true]) func newerSchemaIsGatedOnlyByWriterVersion(
    raisedVersion: Bool
  ) throws {
    try withScratchDirectory { scratch in
      let store = Self.store(scratch)
      try store.initialize()
      let queue = try DatabaseQueue(path: store.path)
      try queue.write { db in
        try db.execute(sql: "INSERT INTO grdb_migrations VALUES('future')")
        if raisedVersion {
          try db.execute(sql: "UPDATE meta SET value='2' WHERE key='min_writer_version'")
        }
      }
      let older = Self.store(scratch)
      if raisedVersion {
        #expect(throws: StorageError.schemaTooNew) { try older.initialize() }
      } else {
        _ = try older.write { try StorageWriteTests.insert($0, uid: "acme") }
      }
      #expect(
        try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") } == 2)
    }
  }

  @Test func futureSchemaRefusalPreservesJournalMode() throws {
    try withScratchDirectory { scratch in
      let queue = try DatabaseQueue(path: scratch.appending(path: "silta.db").path)
      try StorageSchema.migrator.migrate(queue)
      try queue.write {
        try $0.execute(sql: "UPDATE meta SET value='2' WHERE key='min_writer_version'")
      }
      #expect(try queue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "delete")
      #expect(throws: StorageError.schemaTooNew) { try Self.store(scratch).initialize() }
      let fresh = try DatabaseQueue(path: scratch.appending(path: "silta.db").path)
      let mode = try fresh.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
      #expect(mode == "delete")
    }
  }

  @Test func storageErrorGoldenAndPrivacy() {
    var blocks: [String] = []
    for error in StorageError.allCases {
      let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
      let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
      blocks.append("## \(error)\n\(text.stderr)\(json.stdout)")
    }
    Golden.forTests().check(blocks.joined(separator: "\n"), "storage-errors.txt")
    let underlying = DatabaseError(
      resultCode: .SQLITE_ERROR, message: "acme-private-value", sql: "acme-private-sql")
    let error = StorageError.mapped(underlying)
    #expect(!String(reflecting: error).contains("acme-private"))
    #expect(!error.message.contains("acme-private"))
  }
}
