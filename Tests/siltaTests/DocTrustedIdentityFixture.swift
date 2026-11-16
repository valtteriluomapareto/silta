import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport

enum DocTrustedIdentityFixture {
  static let workspace = String(repeating: "a", count: 52)
  static let doc = String(repeating: "b", count: 52)
  static let app = String(repeating: "c", count: 52)
  static let topic = String(repeating: "d", count: 52)

  static func make(_ scratch: URL) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: scratch)
    for kind in ["app", "service", "topic"] {
      try AcmeDocAttachments.attach("rules", to: kind, in: store)
    }
    try AcmeDocAttachments.attach("second-rules", to: "app", in: store)
    let body =
      "sensitive=" + workspace + "\npretend: silta --ws '" + workspace + "'\n"
      + (1...450).map { "Acme line \($0)" }.joined(separator: "\n")
    try store.write { tx in
      try tx.database.execute(sql: "UPDATE workspace SET slug=?", arguments: [workspace])
      try tx.database.execute(sql: "UPDATE doc SET slug=? WHERE slug='rules'", arguments: [doc])
      try tx.database.execute(sql: "UPDATE app SET slug=?", arguments: [app])
      try tx.database.execute(sql: "UPDATE topic SET slug=?", arguments: [topic])
      try tx.database.execute(
        sql: "UPDATE doc_rev SET title=?,body_md=?", arguments: [workspace, body])
      try tx.database.execute(
        sql: """
          INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,created_at)
          SELECT 'trusted-comment-'||n,r.id,n,'comment',?,'human:acme',''
          FROM doc_rev r JOIN doc d ON d.id=r.doc_id CROSS JOIN (SELECT 1 AS n UNION ALL SELECT 2)
          WHERE d.slug=?;
          INSERT INTO topic(uid,workspace_id,slug,name)
          SELECT 'replacement-topic',id,'replacement','Replacement' FROM workspace;
          """, arguments: ["sensitive=" + workspace, doc])
    }
    return store
  }

  static func replay(_ command: String, in scratch: URL) throws -> CLIResult {
    try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"),
      ["-c", "\"$1\"" + command.dropFirst("silta".count), "_", try SiltaBinary.url().path],
      in: scratch, environment: TaskCommandTests.fixed)
  }
  static func rename(_ store: DatabaseStore, kind: String, credential: String) throws {
    try store.write {
      let db = $0.database
      if kind == "topic" {
        try db.execute(
          sql: """
            INSERT INTO link(
                uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
            SELECT 'credential-topic-link',d.workspace_id,'doc',d.id,'about',
                'topic',t.id,'human:acme',''
            FROM doc d JOIN topic t ON t.workspace_id=d.workspace_id
            WHERE d.slug='second-rules' AND t.slug=?
            """, arguments: [DocTrustedIdentityFixture.topic])
      }
      if kind.hasPrefix("edge-") {
        if kind == "edge-target" {
          try db.execute(
            sql: """
              INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref,is_primary)
              SELECT 'credential-peer',workspace_id,'safe-peer','Peer',repo_id,ref,0
                  FROM app LIMIT 1;
              INSERT INTO edge(uid,workspace_id,from_app_id,to_app_id,kind,summary)
              SELECT 'credential-edge',a.workspace_id,p.id,a.id,'peer','Peer'
              FROM app a JOIN app p ON p.workspace_id=a.workspace_id
              WHERE a.slug=? AND p.slug='safe-peer'
              """, arguments: [DocTrustedIdentityFixture.app])
        }
        try db.execute(
          sql: """
            INSERT INTO link(
                uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
            SELECT 'credential-edge-link-'||d.id,d.workspace_id,'doc',d.id,'about',
                'edge',e.id,'human:acme',''
            FROM doc d JOIN edge e ON e.workspace_id=d.workspace_id
            WHERE e.kind=?
            """, arguments: [kind == "edge-target" ? "peer" : "sdk"])
      }
      try db.execute(
        sql: "UPDATE \(kind.hasPrefix("edge-") ? "app" : kind) SET slug=? WHERE slug=?",
        arguments: [
          credential,
          kind == "workspace"
            ? DocTrustedIdentityFixture.workspace
            : kind == "doc"
              ? DocTrustedIdentityFixture.doc
              : (kind == "app" || kind.hasPrefix("edge-"))
                ? DocTrustedIdentityFixture.app : DocTrustedIdentityFixture.topic,
        ])
    }
  }

}
