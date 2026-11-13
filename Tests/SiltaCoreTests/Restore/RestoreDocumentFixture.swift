import Foundation
import GRDB
import Testing

@testable import SiltaCore

/// Historical document rows and retained workspace state for restore transactions.
enum RestoreDocumentFixture {
  static func source(_ home: URL) throws -> DatabaseStore {
    let store = try RestoreDocumentGraphFixture.source(home)
    try store.write {
      try $0.database.execute(
        sql: """
          UPDATE task SET claimed_by='agent:codex:acme',claimed_at='2023-11-14T22:13:00.000Z',
            branch='feature/docs' WHERE id=700;
          INSERT INTO seq_counter(scope,next) VALUES('task:17',2);
          UPDATE task SET plan_rev=2,plan_md='v2' WHERE id=700;
          INSERT INTO task_plan_rev(id,task_id,rev,body_md,actor,created_at)
          VALUES(1601,700,1,'v1','human:acme',''),(1602,700,2,'v2','human:acme','');
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_ext,
            created_by,created_at)
          VALUES('note-nfc',17,'task',700,'cites','note',:nfc,'human:acme',''),
            ('note-nfd',17,'task',700,'cites','note',:nfd,'human:acme','');
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
            created_by,created_at)
          VALUES('plan-one',17,'task',700,'cites','task_plan_rev',1601,'human:acme',''),
            ('plan-two',17,'task',700,'cites','task_plan_rev',1602,'human:acme','');
          """, arguments: ["nfc": "caf\u{e9}", "nfd": "cafe\u{301}"])
    }
    return store
  }

  static func commentSequence(_ store: DatabaseStore) throws -> Int64 {
    let owner = try #require(
      try store.read {
        try Int64.fetchOne(
          $0, sql: "SELECT id FROM doc_rev WHERE uid=?",
          arguments: [ExportDocumentTests.uid("003")])
      })
    return try store.write { try $0.nextSequence(scope: "comment:doc_rev:\(owner)") }
  }

  static func retained(_ store: DatabaseStore) throws -> [[String]] {
    let queries = [
      "SELECT * FROM workspace WHERE id=23", "SELECT * FROM doc WHERE workspace_id=23",
      "SELECT * FROM doc_rev WHERE doc_id=92", "SELECT * FROM link WHERE workspace_id=23",
      """
      SELECT * FROM seq_counter WHERE scope IN
        ('doc_rev:23:gone-rules','comment:doc_rev:950','comment:doc_rev:4040404')
      """,
      "SELECT r.uid,p.path,p.fetched_at FROM repo_path p JOIN repo r ON r.id=p.repo_id",
      "SELECT a.uid,o.path,o.set_by FROM worktree_override o JOIN app a ON a.id=o.app_id",
      "SELECT uid,worktree,claimed_by,claimed_at,branch FROM task WHERE workspace_id=17",
    ]
    return try store.read { db in
      try queries.map { try Row.fetchAll(db, sql: $0).map(\.description) }
    }
  }
}
