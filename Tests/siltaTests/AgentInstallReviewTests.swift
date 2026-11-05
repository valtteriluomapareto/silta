import Foundation
import SiltaTestSupport
import Testing

struct AgentInstallReviewTests {
  @Test(arguments: ["install", "uninstall"])
  func unownedFrontmatterIsNeverAdopted(operation: String) throws {
    try withScratchDirectory { scratch in
      let original = "---\nname: silta\ndescription: Use Silta for context, "
        + "backlog, plans and handoffs across repositories.\n---\n"
      try AgentsInstallTests.write(original, ".claude/skills/silta/SKILL.md", in: scratch)
      withKnownIssue("#17: unowned skill frontmatter must survive") { () throws in
        let result = try AgentsInstallTests.run([operation, "--claude", "--json"], in: scratch)
        #expect(result.termination == .exit(6))
        if result.termination == .exit(0) {
          let token = try #require(try AgentsInstallTests.data(result)["token"] as? String)
          _ = try AgentsInstallTests.run([operation, "--claude", "--apply", token], in: scratch)
        }
        #expect(try AgentsInstallTests.read(".claude/skills/silta/SKILL.md", in: scratch) == original)
        #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.claude/CLAUDE.md").path))
      }
    }
  }

  @Test(arguments: ["--claude", "--codex"])
  func unselectedOverridesAreIgnored(selection: String) throws {
    try withScratchDirectory { scratch in
      let key = selection == "--claude" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
      let env = [key: scratch.appending(path: "other-config").path]
      withKnownIssue("#17: unselected harness overrides are irrelevant") { () throws in
        #expect(try AgentsInstallTests.run(["install", selection, "--json"], in: scratch, environment: env).termination == .exit(0))
      }
    }
  }

  @Test(arguments: ["model = \"unterminated\n", "model =\n", "models = [\"acme\"\n", "[profile] trailing\n"])
  func malformedTOMLRefusesEveryWrite(text: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(text, ".codex/config.toml", in: scratch)
      withKnownIssue("#17: conservative TOML acceptance covers complete lines") { () throws in
        #expect(try AgentsInstallTests.run(["install", "--json"], in: scratch).termination == .exit(6))
      }
      #expect(try AgentsInstallTests.read(".codex/config.toml", in: scratch) == text)
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.claude").path))
    }
  }
}
