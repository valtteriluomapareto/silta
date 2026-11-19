import CryptoKit
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

  /// An owned block sealed with `origin`: `keep` when the file existed before install.
  static func sealed(_ body: String, origin: String) -> String {
    let digest = SHA256.hash(data: Data((origin + ":" + body).utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "\n<!-- silta:begin \(digest):\(origin) -->\n" + body + "<!-- silta:end -->\n"
  }

  /// The instruction file and another file the same harness install owns.
  static let files = [
    "claude": (path: ".claude/CLAUDE.md", other: ".claude/settings.json"),
    "codex": (path: ".codex/AGENTS.md", other: ".codex/config.toml"),
  ]

  @Test(arguments: ["claude", "codex"], ["new", "keep"])
  func olderPlanRuleIsStaleAndUpgradesOnlyItsBlock(_ harness: String, _ origin: String) throws {
    let files = try #require(Self.files[harness])
    try withScratchDirectory { scratch in
      let env = try AgentHealthTests.setup(scratch)
      let other = try AgentsInstallTests.read(files.other, in: scratch)
      let older = Self.userText + Self.sealed(Self.olderInstructions, origin: origin)
      try AgentsInstallTests.write(older, files.path, in: scratch)

      let id = "install.\(harness).instructions"
      let stale = try AgentHealthTests.check(id, in: AgentHealthTests.checks(scratch, env))
      #expect(stale["status"] as? String == "warning")
      #expect(stale["next_by"] as? String == "agent")
      let next = try #require((stale["next"] as? [String])?.first)
      #expect(next == "silta agents install --\(harness) --dry-run")

      let words = next.split(separator: " ").dropFirst().map(String.init)
      let preview = try GuideContractTests.object(
        SiltaBinary.run(words + ["--json"], in: scratch, environment: env).stdout)
      let data = try #require(preview["data"] as? [String: Any])
      let changes = try #require(data["changes"] as? [[String: String]])
      #expect(changes.map { $0["path"] } == [files.path])
      let diff = try #require(changes.first?["diff"])
      #expect(diff.contains("-Keep plans and results in Silta; never create repo plan files"))
      #expect(diff.contains("+only when the repo's own instructions require one"))

      let args = ["install", "--\(harness)"]
      let applied = try AgentsInstallTests.apply(args, in: scratch, environment: env)
      #expect(applied.termination == .exit(0), "\(applied.stdout)\(applied.stderr)")
      let updated = try AgentsInstallTests.read(files.path, in: scratch)
      #expect(updated.hasPrefix(Self.userText))
      #expect(updated.contains(":\(origin) -->"))
      #expect(!updated.contains("never create repo plan files or tracker items"))
      #expect(try AgentsInstallTests.read(files.other, in: scratch) == other)
      let current = try AgentHealthTests.check(id, in: AgentHealthTests.checks(scratch, env))
      #expect(current["status"] as? String == "pass")
    }
  }
}
