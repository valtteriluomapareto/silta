import CryptoKit
import Foundation
import GRDB
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentCommandTests {

  static func export(_ scratch: URL, workspace: String = "acme") throws -> URL {
    let result = try SiltaBinary.run(["--ws", workspace, "export", "--to", "out"], in: scratch)
    try #require(result.termination == .exit(0), "\(result.stderr)")
    return scratch.appending(path: "work/out/" + workspace)
  }

  @Test func nonzeroDocumentDryRunMatchesTextAndJSONContract() throws {
    try withScratchDirectory { scratch in
      try RestoreDocumentCommandFixture.seed(scratch)
      _ = try Self.export(scratch)
      let queue = try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path)
      try queue.write {
        try $0.execute(
          sql: """
            UPDATE doc SET title='Changed projection' WHERE id=100;
            UPDATE doc_rev SET body_md='Changed body' WHERE id=200;
            INSERT INTO doc(id,uid,workspace_id,slug,title,kind,created_at,updated_at)
            VALUES(101,'removed-doc',1,'removed-rules','Removed','runbook','','');
            INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
            VALUES('removed-proposal',101,7,'Pending','proposed','human:acme','');
            INSERT INTO seq_counter(scope,next) VALUES('doc_rev:1:removed-rules',8);
            """)
      }
      let before = try RestoreDocumentCommandFixture.dump(queue)
      for json in [false, true] {
        let result = try SiltaBinary.run(
          ["restore", "out/acme", "--dry-run"] + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(0), "\(result.stderr)\(result.stdout)")
        Golden.forTests().check(
          RestoreCommandTests.masked(result.stdout, scratch),
          json ? "restore-docs-dry-run.json" : "restore-docs-dry-run.txt")
        #expect(try RestoreDocumentCommandFixture.dump(queue) == before)
      }
      let restored = try SiltaBinary.run(
        ["restore", "out/acme", "--approved", "yes, restore the docs"], in: scratch,
        environment: RestoreCommandTests.agent)
      #expect(restored.termination == .exit(0), "\(restored.stderr)")
      #expect(restored.stdout.contains("Docs: 2 -> 1."))
      try queue.read { (db: Database) throws in
        #expect(try String.fetchOne(db, sql: "SELECT title FROM doc") == "Policy")
        #expect(try String.fetchOne(db, sql: "SELECT body_md FROM doc_rev") == "Original rule.")
      }
    }
  }

  @Test(
    arguments: ["doc", "workspace"],
    ["ghp_" + String(repeating: "x", count: 36), String(repeating: "a", count: 52)])
  func malformedDocumentDiagnosticsProtectScopeAndIdentity(_ target: String, _ name: String) throws
  {
    try withScratchDirectory { scratch in
      let workspace = target == "workspace" ? name : "acme"
      let slug = target == "doc" ? name : "rules"
      try RestoreDocumentCommandFixture.seed(scratch, workspace: workspace, slug: slug)
      let directory = try Self.export(scratch, workspace: workspace)
      let path = directory.appending(path: "docs/" + slug + ".jsonl")
      let original = try Data(contentsOf: path)
      let originalText = try #require(String(bytes: original, encoding: .utf8))
      var lines = originalText.split(separator: "\n").map(String.init)
      let index = try #require(lines.firstIndex { $0.hasPrefix(#"{"table": "doc_rev""#) })
      lines[index] =
        String(lines[index].dropLast()) + #", "triaged_at": "2023-11-14T22:13:20.000Z"}"#
      let changed = Data((lines.joined(separator: "\n") + "\n").utf8)
      try changed.write(to: path)
      let manifest = directory.appending(path: "manifest.json")
      let manifestText = try String(contentsOf: manifest, encoding: .utf8)
      try Data(
        manifestText.replacingOccurrences(of: Self.digest(original), with: Self.digest(changed))
          .utf8
      ).write(to: manifest)
      let queue = try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path)
      let before = try RestoreDocumentCommandFixture.dump(queue)
      var output = ""
      for json in [false, true] {
        let result = try SiltaBinary.run(
          ["restore", directory.path, "--dry-run"] + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(1))
        let shown = result.stdout + result.stderr
        #expect(shown.contains("only one triage audit field"))
        if target == "workspace" || name.count != 52 {
          #expect(!shown.contains(name), "\(shown)")
        } else {
          #expect(shown.contains("doc:" + name + "@1"))
        }
        if target == "workspace" {
          if json {
            #expect(shown.contains(#""next":["silta ws ls"],"next_by":"agent""#))
          } else {
            #expect(shown.hasSuffix("next: silta ws ls\n"))
          }
        }
        output += result.stderr + result.stdout
        #expect(try RestoreDocumentCommandFixture.dump(queue) == before)
      }
      if target == "workspace", name.hasPrefix("ghp_") {
        Golden.forTests().check(output, "restore-docs-unsafe-scope.txt")
      }
    }
  }

  @Test func committedSnapshotPathIsMaskedInJSON() throws {
    try withScratchDirectory { scratch in
      try RestoreDocumentCommandFixture.seed(scratch)
      let directory = try Self.export(scratch)
      let secret = "ghp_" + String(repeating: "x", count: 36)
      let home = scratch.appending(path: secret)
      try FileManager.default.moveItem(at: scratch.appending(path: "silta-home"), to: home)
      let result = try SiltaBinary.run(
        ["restore", directory.path, "--approved", "Restore these rules", "--json"], in: scratch,
        environment: RestoreCommandTests.agent.merging(["SILTA_HOME": home.path]) { _, new in new })
      #expect(result.termination == .exit(0), "\(result.stderr)\(result.stdout)")
      #expect(!result.stdout.contains(secret))
      let object = try #require(
        try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let data = try #require(object["data"] as? [String: Any])
      let snapshot = try #require(data["snapshot"] as? String)
      #expect(snapshot.contains("[REDACTED:github_pat]"))
      #expect(
        !(try FileManager.default.contentsOfDirectory(atPath: home.appending(path: "backups").path))
          .isEmpty)
    }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

}
