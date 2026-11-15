import Foundation
import GRDB

@testable import SiltaCore

/// Actual SQLite identities that compare canonically equal as Swift strings.
enum RestoreOpaqueIdentityFixture {
  static func nfc(_ kind: String) -> String { kind + "-caf\u{e9}" }
  static func nfd(_ kind: String) -> String { kind + "-cafe\u{301}" }

  static func documents(_ home: URL) throws -> DatabaseStore {
    let store = try RestoreDocumentGraphFixture.source(home)
    try store.write { tx in
      try tx.database.execute(
        sql: """
          UPDATE doc SET uid=:doc1 WHERE id=91;
          INSERT INTO doc(id,uid,workspace_id,slug,title,kind,current_rev,archived,
          created_at,updated_at)
          VALUES(101,:doc2,17,'other-rules','Other policy','design',1,1,'','');
          INSERT INTO doc_rev(id,uid,doc_id,rev,body_md,state,actor,created_at)
          VALUES(1200,'second-revision',101,1,'Other body','accepted','human:acme','');
          UPDATE task SET uid=:task1 WHERE id=700;
          INSERT INTO task(id,uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
          VALUES(1800,:task2,17,2,'Second source','todo','human:acme','','');
          UPDATE doc_rev SET uid=:rev1,source_task_id=700 WHERE id=902;
          UPDATE doc_rev SET uid=:rev2,source_task_id=1800 WHERE id=901;
          UPDATE comment SET uid=:comment1,doc_rev_id=902 WHERE id=44;
          UPDATE comment SET uid=:comment2,seq=1,thread_id=NULL WHERE id=45;
          INSERT INTO comment(uid,doc_rev_id,seq,thread_id,kind,body_md,actor,created_at)
          VALUES('comment-child',901,3,45,'comment','A child','human:acme','');
          UPDATE seq_counter SET next=27 WHERE scope='comment:doc_rev:901';
          INSERT INTO seq_counter(scope,next) VALUES('comment:doc_rev:902',13);
          """,
        arguments: [
          "doc1": nfc("doc"), "doc2": nfd("doc"), "rev1": nfc("rev"), "rev2": nfd("rev"),
          "task1": nfc("task"), "task2": nfd("task"),
          "comment1": nfc("comment"), "comment2": nfd("comment"),
        ])
    }
    return store
  }

  static func rename(_ tree: inout ExportSnapshot, from old: String, to new: String) {
    func row(_ original: ExportRow) -> ExportRow {
      var result = original
      for index in result.fields.indices {
        if ["uid", "from", "to", "thread", "doc_rev", "source_task", "parent"].contains(
          result.fields[index].key),
          result.fields[index].value.utf8.elementsEqual(old.utf8)
        {
          result.fields[index].value = new
        }
      }
      return result
    }
    for index in tree.tasks.indices {
      tree.tasks[index].row = row(tree.tasks[index].row)
      tree.tasks[index].records = tree.tasks[index].records.map(row)
    }
    for index in tree.documents.documents.indices {
      tree.documents.documents[index].row = row(tree.documents.documents[index].row)
      tree.documents.documents[index].records = tree.documents.documents[index].records.map(row)
    }
    tree.documents.commentSequences = tree.documents.commentSequences.map(row)
    tree.links = tree.links.map(row)
  }

  static func machineRows(_ store: DatabaseStore) throws -> [String: [Data]] {
    let queries = [
      "repo": """
      SELECT r.uid,p.path FROM repo_path p JOIN repo r ON r.id=p.repo_id
      ORDER BY r.uid COLLATE BINARY
      """,
      "app": """
      SELECT a.uid,o.path FROM worktree_override o JOIN app a ON a.id=o.app_id
      ORDER BY a.uid COLLATE BINARY
      """,
      "task":
        "SELECT uid,worktree FROM task WHERE worktree IS NOT NULL ORDER BY uid COLLATE BINARY",
    ]
    return try store.read { db in
      try queries.mapValues { sql in
        try Row.fetchAll(db, sql: sql).map { Data($0.description.utf8) }
      }
    }
  }
}
