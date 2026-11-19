import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct AgentInstallPlanRuleTests {
  /// The instruction block older binaries wrote, before repository plan rules won.
  static let olderInstructions = """
    If `silta where` resolves this repo, use Silta for cross-repo work and backlog.
    Read `silta brief` at session start unless the hook already printed it.
    Read docs shown in the brief before cross-app work; details: `silta guide docs`.
    Keep plans and results in Silta; never create repo plan files or tracker items.
    Leave a handoff before stopping; read errors and their next commands.
    Details: `silta guide`.
    """ + "\n"

  static let userText = "# Acme personal notes\nPrefer small commits.\n"

  @Test(arguments: [("claude", ".claude/CLAUDE.md"), ("codex", ".codex/AGENTS.md")])
  func olderPlanRuleIsStaleAndUpgradesOnlyItsBlock(_ harness: String, _ path: String) throws {
    try withScratchDirectory { scratch in
      let env = try AgentHealthTests.setup(scratch)
      let settings = try AgentsInstallTests.read(".claude/settings.json", in: scratch)
      let older =
        Self.userText + AgentInstallSkillStubTests.ownedBlock(Self.olderInstructions)
      try AgentsInstallTests.write(older, path, in: scratch)

      let id = "install.\(harness).instructions"
      let stale = try AgentHealthTests.check(id, in: AgentHealthTests.checks(scratch, env))
      #expect(stale["status"] as? String == "warning")
      #expect(stale["next_by"] as? String == "agent")
      #expect(stale["next"] as? [String] == ["silta agents install --\(harness) --dry-run"])

      let args = ["install", "--\(harness)"]
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(args + ["--json"], in: scratch, environment: env))
      let changes = try #require(preview["changes"] as? [[String: String]])
      #expect(changes.map { $0["path"] } == [path])
      let diff = try #require(changes.first?["diff"])
      #expect(diff.contains("-Keep plans and results in Silta; never create repo plan files"))
      #expect(diff.contains("+unless the repo's own instructions require one"))

      let applied = try AgentsInstallTests.apply(args, in: scratch, environment: env)
      #expect(applied.termination == .exit(0), "\(applied.stdout)\(applied.stderr)")
      let updated = try AgentsInstallTests.read(path, in: scratch)
      #expect(updated.hasPrefix(Self.userText))
      #expect(!updated.contains("never create repo plan files or tracker items"))
      #expect(try AgentsInstallTests.read(".claude/settings.json", in: scratch) == settings)
      let current = try AgentHealthTests.check(id, in: AgentHealthTests.checks(scratch, env))
      #expect(current["status"] as? String == "pass")
    }
  }
}
