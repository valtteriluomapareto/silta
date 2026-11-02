import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StorageSchemaTests {
  static let instant = Date(timeIntervalSince1970: 1_700_000_000)

  static func store(_ home: URL, seed: UInt64 = 0) -> DatabaseStore {
    DatabaseStore(home: home, clock: FakeClock(now: instant), ids: SeededIDGenerator(seed: seed))
  }

  @Test func constructionAndMissingReadNeverInitialize() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "data")
      let store = Self.store(home)
      #expect(!FileManager.default.fileExists(atPath: home.path))
      #expect(throws: StorageError.unavailable) { try store.read { _ in () } }
      #expect(!FileManager.default.fileExists(atPath: home.path))
      let environment = try SiltaEnvironment.system(
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
        let actual = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        #expect(Set(actual) == expected)
        #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
        #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1)
        #expect(try Int.fetchOne(db, sql: "PRAGMA busy_timeout") == 5000)
        #expect(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'") == "1")
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(task)").map { $0["name"] as String }
        #expect(columns.contains("claimed_at") && columns.contains("plan_rev") && columns.contains("done_sha"))
      }
      let backups = try FileManager.default.contentsOfDirectory(atPath: scratch.appending(path: "backups").path)
      #expect(backups.count == 1)
      let initial = try DatabaseQueue(path: scratch.appending(path: "backups").appending(path: backups[0]).path)
      try initial.read { db in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='table'") == 0)
        #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
      }
      try Self.store(scratch, seed: 1).initialize()
      #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.appending(path: "backups").path) == backups)
    }
  }

  @Test func workspaceRecordsAndConstraints() throws {
    try withScratchDirectory { scratch in
      let store = Self.store(scratch)
      try store.initialize()
      let queue = try DatabaseQueue(path: store.path)
      try queue.write { db in
        var workspace = Workspace(uid: "acme-workspace", slug: "acme", name: "Acme", taskPrefix: "AC")
        try workspace.insert(db)
        #expect(try Workspace.fetchOne(db) == workspace)
        #expect(throws: DatabaseError.self) { try workspace.insert(db) }
        #expect(throws: DatabaseError.self) {
          try db.execute(sql: "INSERT INTO repo(uid,workspace_id,slug) VALUES('acme-repo',999,'platform')")
        }
        #expect(throws: DatabaseError.self) {
          try db.execute(sql: "INSERT INTO comment(uid,seq,kind,body_md,actor,created_at) VALUES('acme-comment',1,'comment','','agent:unknown:acme','2023-11-14T22:13:20.000Z')")
        }
        #expect(throws: DatabaseError.self) {
          try db.execute(sql: "INSERT INTO edge(uid,workspace_id,from_app_id,kind,summary) VALUES('acme-edge',1,1,'http','Acme')")
        }
      }
      #expect(throws: StorageError.unavailable) {
        try store.read { db in try db.execute(sql: "DELETE FROM workspace") }
      }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 1)
    }
  }

  @Test func unknownFutureSchemaIsRefusedWithoutMigration() throws {
    try withScratchDirectory { scratch in
      let store = Self.store(scratch)
      try store.initialize()
      let queue = try DatabaseQueue(path: store.path)
      try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES('future')") }
      #expect(throws: StorageError.schemaTooNew) { try Self.store(scratch, seed: 1).initialize() }
      #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") } == 2)
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
    let underlying = DatabaseError(resultCode: .SQLITE_ERROR, message: "acme-private-value", sql: "acme-private-sql")
    let error = StorageError.mapped(underlying)
    #expect(!String(reflecting: error).contains("acme-private"))
    #expect(!error.message.contains("acme-private"))
  }
}
