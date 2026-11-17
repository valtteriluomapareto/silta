package import Foundation
import GRDB
package import SiltaCore

/// A small workspace with each supported kind of document attachment.
package enum AcmeDocAttachments {
  package static let instant = Date(timeIntervalSince1970: 1_700_000_000)

  package static func make(in scratch: URL) throws -> DatabaseStore {
    let store = DatabaseStore(
      home: scratch.appending(path: "silta-home"), clock: FakeClock(now: instant), jitter: { 0 })
    try apply(yaml(), to: store)
    return store
  }

  package static func yaml(removing kind: String? = nil, name: String = "Acme") -> String {
    let apps = kind != "app" && kind != "repo"
    return """
      workspace: {slug: acme, name: \(name), task_prefix: AC}
      repos: \(kind == "repo" ? "[]" : "[{slug: platform}]")
      apps: \(apps ? "[{slug: api, repo: platform, ref: main}]" : "[]")
      services: \(kind == "service" ? "[]" : "[push]")
      edges: \(apps && kind != "service" && kind != "edge" ? "[{from: api, to: service:push, kind: sdk, summary: Push}]" : "[]")
      topics: \(kind == "topic" ? "[]" : "[{slug: messaging}]")

      """
  }

  package static func apply(_ yaml: String, to store: DatabaseStore) throws {
    let config = try WorkspaceConfig.parse(yaml)
    try store.write { try config.apply(in: $0, ids: SeededIDGenerator(seed: 1), at: instant) }
  }

  package static func attach(
    _ slug: String, to kind: String, in store: DatabaseStore,
    state: String = "accepted", archived: Bool = false, relation: String = "about"
  ) throws {
    try store.write { tx in
      let db = tx.database
      try db.execute(
        sql: """
          INSERT INTO doc(
            uid,workspace_id,slug,title,kind,current_rev,archived,created_at,updated_at)
          SELECT ?,id,?,'Private Acme title','reference',?,?,?,? FROM workspace
          WHERE slug='acme' ON CONFLICT(workspace_id,slug) DO NOTHING
          """,
        arguments: [
          "doc-" + slug, slug, state == "accepted" ? 1 : nil, archived,
          "2023-11-14T22:13:20.000Z", "2023-11-14T22:13:20.000Z",
        ])
      try db.execute(
        sql: """
          INSERT INTO doc_rev(id,uid,doc_id,rev,body_md,state,actor,created_at)
          SELECT id+100,?,id,1,'Private Acme body',?,'human:acme',? FROM doc
          WHERE slug=? ON CONFLICT(doc_id,rev) DO NOTHING
          """, arguments: ["rev-" + slug, state, "2023-11-14T22:13:20.000Z", slug])
      try db.execute(
        sql: """
          INSERT INTO link(
            uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
          SELECT ?,doc.workspace_id,'doc',doc.id,?,?,target.id,'human:acme',?
          FROM doc CROSS JOIN \(kind) target WHERE doc.slug=?
          """,
        arguments: [
          "link-" + slug + "-" + kind, relation, kind, "2023-11-14T22:13:20.000Z", slug,
        ])
    }
  }

  /// Retains identical Acme rules proposals for history and cleanup controls.
  package static func copyLatestRulesProposal(in store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql: """
          INSERT INTO doc_rev(uid,doc_id,rev,base_rev,body_md,state,actor,message,created_at,
            title,kind,about_refs,about_targets,source_task_id)
          SELECT uid||'-history',doc_id,rev+1,base_rev,body_md,state,actor,message,created_at,
            title,kind,about_refs,about_targets,source_task_id FROM doc_rev
          WHERE state='proposed' AND doc_id=(
            SELECT id FROM doc WHERE workspace_id=1 AND slug='rules')
          ORDER BY rev DESC LIMIT 1;
          UPDATE seq_counter SET next=next+1 WHERE scope='doc_rev:1:rules';
          """)
    }
  }

}
