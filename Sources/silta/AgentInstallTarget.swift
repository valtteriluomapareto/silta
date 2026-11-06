import Foundation

struct AgentInstallTarget {
  let path: String
  let body: String
  let whole: Bool
  let settings: Bool
  let stopHook: Bool

  init(path: String, body: String, whole: Bool, settings: Bool = false, stopHook: Bool = false) {
    self.path = path
    self.body = body
    self.whole = whole
    self.settings = settings
    self.stopHook = stopHook
  }
  private static let frontmatter =
    "---\nname: silta\ndescription: Use Silta for context, "
    + "backlog, plans and handoffs across repositories.\n---\n"

  static func selected(claude: Bool, codex: Bool, root: String) throws -> [Self] {
    let instructions = """
      If `silta where` resolves this repo, use Silta for cross-repo work and backlog.
      Read `silta brief` at session start unless the hook already printed it.
      Keep plans and results in Silta; never create repo plan files or tracker items.
      Leave a handoff before stopping; read errors and their next commands.
      Details: `silta guide`.
      """ + "\n"
    var targets: [Self] = []
    if claude {
      targets += [
        Self(path: ".claude/skills/silta/SKILL.md", body: GuideCommand.manual(), whole: true),
        Self(path: ".claude/CLAUDE.md", body: instructions, whole: false),
      ]
    }
    if codex {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .withoutEscapingSlashes
      let encoded = String(data: try encoder.encode(root), encoding: .utf8) ?? ""
      targets += [
        Self(path: ".codex/AGENTS.md", body: instructions, whole: false),
        Self(path: ".codex/config.toml", body: encoded, whole: false),
      ]
    }
    return targets
  }

  func previewDiff(
    _ before: String, _ after: String, refusal: () throws -> Never
  ) throws -> String {
    if whole { return AgentInstallPlan.difference(before, after) }
    if path.hasSuffix(".toml") {
      let sign = before.utf8.count < after.utf8.count ? "+" : "-"
      return "\(sign)sandbox_workspace_write.writable_roots \(sign)= \(body)"
    }
    let old = try AgentOwnedBlock(
      before, existed: !before.isEmpty, refusal: refusal)
    let new = try AgentOwnedBlock(
      after, existed: !after.isEmpty, refusal: refusal)
    return AgentInstallPlan.difference(old.span, new.span)
  }

  func replace(
    _ original: String, existed: Bool, uninstall: Bool, refusal: () throws -> Never
  ) throws -> String {
    if settings {
      return try AgentHookSettings.edit(
        original, existed: existed, uninstall: uninstall, stop: stopHook,
        refusal: refusal)
    }
    if path.hasSuffix(".toml") {
      return try AgentTOML.replace(original, value: body, uninstall: uninstall, refusal: refusal)
    }
    var text = original
    if whole {
      guard text.isEmpty || text.hasPrefix(Self.frontmatter) else { try refusal() }
      text = text.isEmpty ? "" : String(text.dropFirst(Self.frontmatter.count))
    }
    let block = try AgentOwnedBlock(
      text, existed: existed, refusal: refusal)
    if whole, !original.isEmpty, !block.owned { try refusal() }
    if whole, !block.outside.isEmpty { try refusal() }
    if uninstall { return block.outside }
    return (whole ? Self.frontmatter : "") + block.render(body)
  }

  func refusalReason(uninstall: Bool) -> String {
    guard path.hasSuffix(".toml") else { return "edited or ambiguous ownership/configuration" }
    let location = "[sandbox_workspace_write].writable_roots"
    let action =
      uninstall
      ? "remove only \(body) from \(location) yourself; retain all other entries"
      : "retain all other entries and add \(body) to \(location); if the key is absent, add this line yourself: writable_roots = [\(body)]"
    return "unsupported or ambiguous TOML; " + action
  }
}
