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

  @Test func reinstallReplacesAnOlderSkillBody() throws {
    try withScratchDirectory { scratch in
      let installed = Self.frontmatter + Self.ownedBlock(Self.legacyBody)
      try AgentsInstallTests.write(installed, ".claude/skills/silta/SKILL.md", in: scratch)
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--claude", "--json"], in: scratch))
      let changes = try #require(preview["changes"] as? [[String: String]])
      let change = try #require(changes.first { $0["path"] == ".claude/skills/silta/SKILL.md" })
      let diff = try #require(change["diff"])
      #expect(diff.contains("-# Recipes"))
      #expect(diff.contains("+Run `silta guide`"))
      let untouched = try AgentsInstallTests.read(".claude/skills/silta/SKILL.md", in: scratch)
      #expect(untouched == installed)
      let applied = try AgentsInstallTests.apply(["install", "--claude"], in: scratch)
      #expect(applied.termination == .exit(0))
      let updated = try AgentsInstallTests.read(".claude/skills/silta/SKILL.md", in: scratch)
      #expect(!updated.contains("# Recipes"))
      Golden.forTests().check(updated, "agents-install-skill.md")
      let again = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--claude", "--json"], in: scratch))
      #expect(again["changes"] as? [[String: String]] == [])
    }
  }
}
