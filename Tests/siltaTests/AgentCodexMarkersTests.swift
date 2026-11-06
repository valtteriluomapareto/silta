import Foundation
import SiltaTestSupport
import Testing

struct AgentCodexMarkersTests {
  static let path = ".codex/config.toml"
  static let tables = """

    [tui]

    [tui.model_availability_nux]

    [projects."/acme/platform"]
    trust_level = "trusted"
    """ + "\n"

  static func seeded(_ scratch: URL, original: String, suffix: String = tables) throws -> String {
    if !original.isEmpty { try AgentsInstallTests.write(original, path, in: scratch) }
    #expect(
      try AgentsInstallTests.apply(["install", "--codex"], in: scratch).termination == .exit(0))
    let installed = try AgentsInstallTests.read(path, in: scratch)
    let edited = installed.replacingOccurrences(of: "# silta:end\n", with: suffix + "# silta:end\n")
    try AgentsInstallTests.write(edited, path, in: scratch)
    return edited
  }

  @Test(arguments: ["install", "uninstall"])
  func codexOwnTablesInsideMarkersRemainUsable(operation: String) throws {
    withKnownIssue("SI-59: Codex tables inside markers refuse ownership") {
      try withScratchDirectory { scratch in
        let original = "cli_auth_credentials_store = \"file\"\n"
        let edited = try Self.seeded(scratch, original: original)
        let before = try AgentInstallRoundTwoTests.snapshot(scratch)
        let preview = try AgentsInstallTests.data(
          AgentsInstallTests.run([operation, "--codex", "--json"], in: scratch))
        #expect(try AgentInstallRoundTwoTests.snapshot(scratch) == before)
        let token = try #require(preview["token"] as? String)
        #expect(
          try AgentsInstallTests.run([operation, "--codex", "--apply", token], in: scratch)
            .termination == .exit(0))
        let expected =
          operation == "install"
          ? edited.replacingOccurrences(
            of: Self.tables + "# silta:end\n", with: "# silta:end\n" + Self.tables)
          : original + Self.tables
        #expect(
          Data(try AgentsInstallTests.read(Self.path, in: scratch).utf8) == Data(expected.utf8))
      }
    }
  }
}
