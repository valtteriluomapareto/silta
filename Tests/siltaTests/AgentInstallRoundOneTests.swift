import Foundation
import SiltaTestSupport
import Testing

struct AgentInstallRoundOneTests {
  static let sentinel = "Acme-private-round-one-sentinel"
  static let path = ".codex/config.toml"

  static func seeded(_ scratch: URL) throws -> String {
    try AgentsInstallTests.write("model = \"\(sentinel)\"\n", path, in: scratch)
    #expect(
      try AgentsInstallTests.apply(["install", "--codex"], in: scratch).termination == .exit(0))
    let text =
      try AgentsInstallTests.read(path, in: scratch)
      + "\n[private]\napi_key = \"\(sentinel)\"\n"
    try AgentsInstallTests.write(text, path, in: scratch)
    return text
  }

  @Test func reinstallRetainsOwnedTableAndPrivateTail() throws {
    try withScratchDirectory { scratch in
      let original = try Self.seeded(scratch)
      let result = try AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch)
      let changes = try AgentsInstallTests.data(result)["changes"] as? [[String: String]]
      #expect(changes == [] && !result.stdout.contains(Self.sentinel))
      #expect(try AgentsInstallTests.read(Self.path, in: scratch) == original)
    }
  }

  @Test(arguments: ["install", "uninstall"], [false, true])
  func changedOwnedSpansNeverExposePrivateConfig(operation: String, json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try Self.seeded(scratch)
      let environment = ["SILTA_HOME": scratch.appending(path: "relocated-data").path]
      let result = try AgentsInstallTests.run(
        [operation, "--codex"] + (json ? ["--json"] : []), in: scratch, environment: environment)
      #expect(result.termination == .exit(0))
      let privateOutput = (result.stdout + result.stderr).contains(Self.sentinel)
      #expect(!privateOutput)
    }
  }

  @Test(arguments: [
    "model = \"one\"\nmodel = \"two\"\n",
    "[profile]\nvalue = 1\n[profile]\nvalue = 2\n",
    "profile = 1\n[profile]\nvalue = 2\n",
    "profile.name = \"one\"\nprofile = \"two\"\n",
  ])
  func duplicateTOMLRefusesBeforeAnyWrite(text: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(text, Self.path, in: scratch)
      let result = try AgentsInstallTests.run(["install", "--json"], in: scratch)
      #expect(result.termination == .exit(6))
      #expect(try AgentsInstallTests.read(Self.path, in: scratch) == text)
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.claude").path))
    }
  }
}
