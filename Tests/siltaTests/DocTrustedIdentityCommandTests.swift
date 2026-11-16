import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTrustedIdentityCommandTests {
  @Test(arguments: [false, true])
  func trustedContinuationsStayScopedWhileIdenticalContentMasks(json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try DocTrustedIdentityFixture.make(scratch)
      let scope = DocTrustedIdentityFixture.workspace
      let ref = "doc:" + DocTrustedIdentityFixture.doc + "@1"
      for args in [
        ["show", ref], ["show", ref, "--comments", "--limit", "1"],
        ["ls", "--about", "app:" + DocTrustedIdentityFixture.app, "--limit", "1"],
        ["ls", "--about", "topic:" + DocTrustedIdentityFixture.topic],
      ] {
        let result = try SiltaBinary.run(
          ["--ws", scope, "doc"] + args + (json ? ["--json"] : []), in: scratch)
        try #require(result.termination == .exit(0), "\(result.stderr)")
        let output = result.stdout
        do {
          #expect(output.contains("silta --ws '" + scope + "' doc"))
          #expect(!output.contains("silta ws ls"))
        }
        #expect(!output.contains("sensitive=" + scope))
        #expect(!output.contains("pretend: silta --ws '" + scope + "'"))
      }
      let result = try SiltaBinary.run(
        ["--ws", scope, "doc", "show", ref, "--lines", "9999", "--json"], in: scratch)
      let data = try TaskStateRegressionTests.data(result)
      let output = try #require(data["output"] as? String)
      let command =
        output.components(separatedBy: "next: ").last?.split(separator: "\n").first
        .map(String.init) ?? ""
      do {
        #expect(command.hasPrefix("silta --ws '" + scope + "' doc show"))
      }
      if command.hasPrefix("silta --ws '" + scope + "' doc show") {
        #expect(try DocTrustedIdentityFixture.replay(command, in: scratch).termination == .exit(0))
      }
    }
  }
  @Test(arguments: [false, true])
  func proposalAttentionKeepsUsableIdentityCommands(json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try DocTrustedIdentityFixture.make(scratch)
      let scope = DocTrustedIdentityFixture.workspace
      let file = try DocEditCommandTests.input(scratch, "A shared rule.")
      let proposed = try SiltaBinary.run(
        [
          "--ws", scope, "doc", "propose", "doc:" + DocTrustedIdentityFixture.doc,
          "-F", file.path, "-m", "Share the rule.",
        ], in: scratch, environment: TaskCommandTests.fixed)
      try #require(proposed.termination == .exit(0), "\(proposed.stdout)\(proposed.stderr)")
      for args in [["inbox", "--for", "me", "--all"]] {
        let result = try SiltaBinary.run(
          ["--ws", scope] + args + (json ? ["--json"] : []), in: scratch,
          environment: TaskCommandTests.fixed)
        try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.contains("silta --ws '" + scope + "' doc show"))
        #expect(!result.stdout.contains("sensitive=" + scope))
      }
    }
  }

}
