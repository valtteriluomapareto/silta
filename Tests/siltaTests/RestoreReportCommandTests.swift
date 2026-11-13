import Foundation
import GRDB
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RestoreReportCommandTests {
  @Test func publishedShapeIncludesDocumentReportFields() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["schema", "restore", "--json"], in: scratch)
      #expect(result.termination == .exit(0), "\(result.stderr)")
      let envelope = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
      let object = try #require(envelope as? [String: Any])
      let data = try #require(object["data"] as? [String: Any])
      let commands = try #require(data["commands"] as? [[String: Any]])
      let shape = try #require(commands.first?["data"] as? [String: Any])
      let fields = try #require(shape["object"] as? [String: Any])
      #expect(fields["docs"] != nil)
      #expect(fields["changed_docs"] != nil && fields["removed_docs"] != nil)
    }
  }

  @Test(arguments: ["ghp_" + String(repeating: "x", count: 36), String(repeating: "a", count: 52)])
  func unsafeWorkspaceIsMaskedAndRecoveryFallsBackBeforeSuffixes(_ name: String) throws {
    try withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path).write {
        try $0.execute(sql: "UPDATE workspace SET slug=?", arguments: [name])
      }
      let exported = try SiltaBinary.run(["--ws", name, "export", "--to", "out"], in: scratch)
      #expect(exported.termination == .exit(0), "\(exported.stderr)")
      for json in [false, true] {
        let result = try SiltaBinary.run(
          ["restore", "out/" + name, "--dry-run"] + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(0), "\(result.stderr)")
        #expect(!result.stdout.contains(name) && !result.stderr.contains(name))
        if !json {
          #expect(result.stdout.hasSuffix("next: silta ws ls\n"))
          #expect(!result.stdout.contains("silta ws ls --"))
        }
      }
    }
  }
}
