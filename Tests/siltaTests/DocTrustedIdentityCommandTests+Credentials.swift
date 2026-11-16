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
      try DocTrustedIdentityFixture.rename(store, kind: kind, credential: credential)
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
