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
          SELECT 'trusted-comment-'||n,r.id,n,'comment','Acme comment','human:acme',''
          FROM doc_rev r JOIN doc d ON d.id=r.doc_id CROSS JOIN (SELECT 1 AS n UNION ALL SELECT 2)
          WHERE d.slug=?;
          INSERT INTO topic(uid,workspace_id,slug,name)
          SELECT 'replacement-topic',id,'replacement','Replacement' FROM workspace;
          """, arguments: [doc])
    }
    return store
  }

  static func replay(_ command: String, in scratch: URL) throws -> CLIResult {
    try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"),
      ["-c", "\"$1\"" + command.dropFirst("silta".count), "_", try SiltaBinary.url().path],
      in: scratch, environment: TaskCommandTests.fixed)
  }
}
