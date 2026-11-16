import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DocTrustedIdentityCommandTests {
  @Test(
    arguments: ["workspace", "doc", "app", "topic", "edge-source", "edge-target"],
    [
      "AKIA1234567890ABCDEF", "ghp_" + String(repeating: "a", count: 36),
      String(repeating: "a", count: 75) + "AZDO" + String(repeating: "b", count: 5),
      String(repeating: "a", count: 76) + "AZDO" + String(repeating: "b", count: 4),
    ])
  func credentialShapedStoredNamesNeverEnterCommands(kind: String, credential: String) throws {
    try withScratchDirectory { scratch in
      let store = try DocTrustedIdentityFixture.make(scratch)
      try store.write {
        let db = $0.database
        if kind == "topic" {
          try db.execute(
            sql: """
              INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
              SELECT 'credential-topic-link',d.workspace_id,'doc',d.id,'about','topic',t.id,'human:acme',''
              FROM doc d JOIN topic t ON t.workspace_id=d.workspace_id
              WHERE d.slug='second-rules' AND t.slug=?
              """, arguments: [DocTrustedIdentityFixture.topic])
        }
        if kind.hasPrefix("edge-") {
          if kind == "edge-target" {
            try db.execute(
              sql: """
                INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref,is_primary)
                SELECT 'credential-peer',workspace_id,'safe-peer','Peer',repo_id,ref,0 FROM app LIMIT 1;
                INSERT INTO edge(uid,workspace_id,from_app_id,to_app_id,kind,summary)
                SELECT 'credential-edge',a.workspace_id,p.id,a.id,'peer','Peer'
                FROM app a JOIN app p ON p.workspace_id=a.workspace_id
                WHERE a.slug=? AND p.slug='safe-peer'
                """, arguments: [DocTrustedIdentityFixture.app])
          }
          try db.execute(
            sql: """
              INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
              SELECT 'credential-edge-link-'||d.id,d.workspace_id,'doc',d.id,'about','edge',e.id,'human:acme',''
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
      let scope = kind == "workspace" ? credential : DocTrustedIdentityFixture.workspace
      let about =
        kind == "edge-source"
        ? "edge:" + credential + "/service:push/sdk"
        : kind == "edge-target" ? "edge:safe-peer/" + credential + "/peer" : kind + ":" + credential
      let args =
        ["workspace", "doc"].contains(kind)
        ? [
          "show", "doc:" + (kind == "doc" ? credential : DocTrustedIdentityFixture.doc), "--lines",
          "9999",
        ]
        : ["ls", "--about", about, "--limit", "1"]
      let result = try SiltaBinary.run(["--ws", scope, "doc"] + args + ["--json"], in: scratch)
      try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      let data = try TaskStateRegressionTests.data(result)
      do {
        #expect(!result.stdout.contains(credential))
        if kind == "workspace" {
          #expect((data["output"] as? String)?.contains("next: silta ws ls") == true)
        } else if kind == "doc" {
          #expect((data["output"] as? String)?.contains("doc ls") == true)
        } else {
          #expect((data["next"] as? String)?.contains("--about") == false)
        }
      }
    }
  }
}
