import Foundation
import GRDB
import SiltaTestSupport

@testable import SiltaCore

/// Real transaction composition for the private document replacement phases.
enum RestoreDocumentRowSupport {
  static func make(_ home: URL) throws -> DatabaseStore {
    let store = try RestoreDocumentGraphFixture.source(home)
    try store.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO doc_rev(id,uid,doc_id,rev,body_md,state,actor,created_at)
          VALUES(1001,'newer-rejection',91,150,'Newer rejected history','rejected','human:acme','');
          INSERT INTO doc(id,uid,workspace_id,slug,title,kind,created_at,updated_at)
          VALUES(100,'removed-doc',17,'removed-rules','Removed policy','runbook','','');
          INSERT INTO doc_rev(id,uid,doc_id,rev,body_md,state,actor,created_at) VALUES
          (1100,'removed-proposal',100,230,'Pending','proposed','human:acme',''),
          (1101,'removed-rejection',100,235,'Rejected','rejected','human:acme','');
          UPDATE seq_counter SET next=88 WHERE scope='doc_rev:17:gone-rules';
          UPDATE seq_counter SET next=99 WHERE scope='comment:doc_rev:901';
          INSERT INTO seq_counter(scope,next) VALUES('doc_rev:17:future-only',333),
            ('comment:doc_rev:1100',500),('comment:doc_rev:1101',600),('task:17',777);
          INSERT INTO repo_path(repo_id,path,fetched_at)
          VALUES(1100,'/private/acme/platform','2023-11-14T22:13:00.000Z');
          INSERT INTO worktree_override(path,app_id,set_by)
          VALUES('/private/acme/doc-worktree',1102,'human:acme');
          UPDATE task SET worktree='/private/acme/source-worktree',branch='feature/docs',
            claimed_by='agent:codex:acme',claimed_at='2023-11-14T22:13:00.000Z' WHERE id=700;
          """)
    }
    return store
  }

  static func replace(
    _ store: DatabaseStore, tree: ExportSnapshot, incoming: ExportDocumentSnapshot,
    rollingBack: Bool = false
  ) throws -> ExportDocumentSnapshot {
    try RestoreDocumentGraph(tree: tree, documents: incoming, slug: "acme").run()
    return try store.write(rollingBack: rollingBack) { tx in
      let current = try ExportDocumentSnapshot.read(tx.database, workspace: 17)
      var writer = RestoreWriter(tx: tx, tree: tree, slug: "acme")
      writer.workspace = 17
      try writer.deleteDocuments(workspace: 17)
      try tx.database.execute(sql: "DELETE FROM link WHERE workspace_id=17")
      // The base rows keep their UID while replacement gives the source task a new id.
      try tx.database.execute(sql: "UPDATE task SET id=1700 WHERE id=700")
      for table in ["task", "repo", "app", "service", "edge", "topic"] {
        for row in try Row.fetchAll(
          tx.database, sql: "SELECT id,uid FROM \(table) WHERE workspace_id=17")
        {
          writer.ids[table, default: [:]][row["uid"]] = row["id"]
        }
      }
      try writer.insertDocuments(incoming, workspace: 17)
      let floors = try writer.restoreDocumentCounters(incoming, retaining: current, workspace: 17)
      try writer.insertLinks(workspace: 17)
      var expected = incoming
      expected.revisionAllocations = floors
      return expected
    }
  }

  static func keptRows(_ store: DatabaseStore) throws -> [[String]] {
    let queries = [
      "SELECT * FROM workspace WHERE id=23", "SELECT * FROM doc WHERE workspace_id=23",
      "SELECT * FROM doc_rev WHERE doc_id=92", "SELECT * FROM link WHERE workspace_id=23",
      "SELECT * FROM seq_counter WHERE scope GLOB 'doc_rev:23:*'",
      """
      SELECT * FROM seq_counter
      WHERE scope IN ('comment:doc_rev:950','comment:doc_rev:4040404','task:17')
      """,
      "SELECT * FROM repo_path", "SELECT * FROM worktree_override",
      "SELECT uid,worktree,claimed_by,claimed_at,branch FROM task WHERE workspace_id=17",
    ]
    return try store.read { db in
      try queries.map { try Row.fetchAll(db, sql: $0).map(\.description) }
    }
  }

  static func accept(_ slug: String, store: DatabaseStore, ids: any IDGenerator) throws
    -> DocRevision
  {
    var draft = DocDraft(slug: slug, body: "A rule after restoring history.")
    draft.title = "Restored policy"
    draft.about = ["service:push%20service"]
    let binding = try DocVerification.readBinding(draft, workspace: 17, store: store)
    return try store.write { tx in
      try DocStore(
        workspace: 17, transaction: tx, actor: DocStoreTests.actor,
        ids: ids, at: ExportFixture.instant
      ).accept(draft, verification: DocVerification(binding: binding, snapshots: []))
    }
  }
}
