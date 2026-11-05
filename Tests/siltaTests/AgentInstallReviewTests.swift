import Foundation
import SiltaTestSupport
import Testing

struct AgentInstallReviewTests {
  @Test(arguments: ["install", "uninstall"])
  func unownedFrontmatterIsNeverAdopted(operation: String) throws {
    try withScratchDirectory { scratch in
      let original =
        "---\nname: silta\ndescription: Use Silta for context, "
        + "backlog, plans and handoffs across repositories.\n---\n"
      try AgentsInstallTests.write(original, ".claude/skills/silta/SKILL.md", in: scratch)
      let result = try AgentsInstallTests.run([operation, "--claude", "--json"], in: scratch)
      #expect(result.termination == .exit(6))
      if result.termination == .exit(0) {
        let token = try #require(try AgentsInstallTests.data(result)["token"] as? String)
        _ = try AgentsInstallTests.run([operation, "--claude", "--apply", token], in: scratch)
      }
      #expect(try AgentsInstallTests.read(".claude/skills/silta/SKILL.md", in: scratch) == original)
      #expect(
        !FileManager.default.fileExists(
          atPath: scratch.appending(path: "home/.claude/CLAUDE.md").path))
    }
  }

  @Test(arguments: ["--claude", "--codex"])
  func unselectedOverridesAreIgnored(selection: String) throws {
    try withScratchDirectory { scratch in
      let key = selection == "--claude" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
      let env = [key: scratch.appending(path: "other-config").path]
      let result = try AgentsInstallTests.run(
        ["install", selection, "--json"], in: scratch, environment: env)
      #expect(result.termination == .exit(0))
    }
  }

  @Test(arguments: [
    "model = \"unterminated\n", "model =\n", "models = [\"acme\"\n", "[profile] trailing\n",
    "value = null\n", "value = {\"json\": 1}\n", "model = \"bad\\/escape\"\n",
    "[broken]]\n", "value = '\u{7f}'\n",
  ])
  func malformedTOMLRefusesEveryWrite(text: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(text, ".codex/config.toml", in: scratch)
      #expect(
        try AgentsInstallTests.run(["install", "--json"], in: scratch).termination == .exit(6))
      #expect(try AgentsInstallTests.read(".codex/config.toml", in: scratch) == text)
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.claude").path))
    }
  }

  @Test func bothHelpRoutesExplainSelectionAndRecovery() throws {
    try withScratchDirectory { scratch in
      for operation in ["install", "uninstall"] {
        let result = try AgentsInstallTests.run([operation, "--help"], in: scratch)
        #expect(result.termination == .exit(0))
        let text = result.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text.contains("Defaults to Claude and Codex."))
        #expect(text.contains("not across files"))
      }
    }
  }
}
