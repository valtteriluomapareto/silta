import CryptoKit
import Foundation
import SiltaTestSupport
import Testing

struct AgentInstallSkillStubTests {
  static let frontmatter =
    "---\nname: silta\ndescription: Use Silta for context, "
    + "backlog, plans and handoffs across repositories.\n---\n"
  static let legacyBody = """
    # When to use Silta
    Use Silta for cross-repo work. Keep plans and results in Silta.

    # Recipes
    Examples use the fictional Acme workspace and task AC-12.
    """ + "\n"

  /// An owned block as an older binary wrote it: the seal covers the origin and body.
  static func ownedBlock(_ body: String) -> String {
    let digest = SHA256.hash(data: Data(("new:" + body).utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "\n<!-- silta:begin \(digest):new -->\n" + body + "<!-- silta:end -->\n"
  }

  static let currentBody = """
    # Silta

    Use Silta for cross-repo work, another app or backend, branch-as-app repos, plans,
    handoffs, review requests and meeting decisions. Trivial single-repo edits need no
    task.

    Run `silta guide` for the current rules, or `silta guide <topic>` for one section.
    Run `silta brief` at session start unless the hook already printed it.
    """ + "\n"

  @Test(arguments: [legacyBody, currentBody])
  func reinstallReplacesAnOlderSkillBody(_ body: String) throws {
    try withScratchDirectory { scratch in
      let installed = Self.frontmatter + Self.ownedBlock(body)
      try AgentsInstallTests.write(installed, ".claude/skills/silta/SKILL.md", in: scratch)
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--claude", "--json"], in: scratch))
      let changes = try #require(preview["changes"] as? [[String: String]])
      let change = try #require(changes.first { $0["path"] == ".claude/skills/silta/SKILL.md" })
      let diff = try #require(change["diff"])
      #expect(diff.contains("+Read workspace docs shown in the brief"))
      #expect(diff.contains("+For document workflows, run `silta guide docs`."))
      let untouched = try AgentsInstallTests.read(".claude/skills/silta/SKILL.md", in: scratch)
      #expect(untouched == installed)
      let applied = try AgentsInstallTests.apply(["install", "--claude"], in: scratch)
      #expect(applied.termination == .exit(0))
      let updated = try AgentsInstallTests.read(".claude/skills/silta/SKILL.md", in: scratch)
      #expect(!updated.contains("# Recipes"))
      #expect(Data(updated.utf8).starts(with: Data(Self.frontmatter.utf8)))
      Golden.forTests().check(updated, "agents-install-skill.md")
      let again = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--claude", "--json"], in: scratch))
      #expect(again["changes"] as? [[String: String]] == [])
    }
  }
  @Test func installedDocsPointersKeepProductRulesInTheGuide() throws {
    try withScratchDirectory { scratch in
      #expect(try AgentsInstallTests.apply(["install"], in: scratch).termination == .exit(0))
      let skill = try AgentsInstallTests.read(".claude/skills/silta/SKILL.md", in: scratch)
      let codex = try AgentsInstallTests.read(".codex/AGENTS.md", in: scratch)
      for text in [skill, codex] {
        #expect(text.contains("silta guide docs"))
        #expect(text.contains("docs shown in the brief"))
        #expect(!text.contains("doc edit") && !text.contains("doc triage"))
      }
      #expect(Data(skill.utf8).starts(with: Data(Self.frontmatter.utf8)))
    }
  }

}
