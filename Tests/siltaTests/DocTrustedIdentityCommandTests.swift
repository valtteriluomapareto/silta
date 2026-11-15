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
        withKnownIssue("SI-135: typed workspace identities are scanned or remasked in commands") {
          #expect(output.contains("silta --ws '" + scope + "' doc"))
          #expect(!output.contains("silta ws ls") && !output.contains("--ws '[REDACTED:"))
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
      withKnownIssue("SI-135: copied document continuation loses its validated workspace") {
        #expect(command.hasPrefix("silta --ws '" + scope + "' doc show"))
      }
      if command.hasPrefix("silta --ws '" + scope + "' doc show") {
        #expect(try DocTrustedIdentityFixture.replay(command, in: scratch).termination == .exit(0))
      }
    }
  }
}
