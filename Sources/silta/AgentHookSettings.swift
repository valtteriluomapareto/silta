import Foundation
import SiltaCore

/// Only an exact sealed hook group is owned; unknown settings stay as JSON values.
enum AgentHookSettings {
  private enum Origin: String, CaseIterable { case file = "new", hooks, event, keep }

  private static let marker = "# silta:session-start:v1:"
  private static let label = "Silta SessionStart"

  static func edit(
    _ original: String, existed: Bool, uninstall: Bool,
    refusal: () throws -> Never
  ) throws -> String {
    var root: [String: Any]
    do { root = existed ? try AgentJSON.object(original) : [:] } catch { try refusal() }
    guard root["hooks"] == nil || root["hooks"] is [String: Any] else { try refusal() }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    guard hooks["SessionStart"] == nil || hooks["SessionStart"] is [[String: Any]] else {
      try refusal()
    }
    var groups = hooks["SessionStart"] as? [[String: Any]] ?? []
    let initial: Origin =
      !existed
      ? .file
      : root["hooks"] == nil ? .hooks : hooks["SessionStart"] == nil ? .event : .keep
    let ownership = try ownership(groups, origin: initial, refusal: refusal)
    let found = ownership.index, origin = ownership.origin
    if uninstall {
      guard let found else { return original }
      groups.remove(at: found)
    } else {
      if found != nil { return original }
      groups.append(group(origin: origin))
    }
    if groups.isEmpty, origin != .keep {
      hooks.removeValue(forKey: "SessionStart")
    } else {
      hooks["SessionStart"] = groups
    }
    if hooks.isEmpty, origin == .file || origin == .hooks {
      root.removeValue(forKey: "hooks")
    } else {
      root["hooks"] = hooks
    }
    if uninstall, origin == .file, root.isEmpty { return "" }
    return try json(root) + "\n"
  }

  private static func ownership(
    _ groups: [[String: Any]], origin: Origin,
    refusal: () throws -> Never
  ) throws -> (index: Int?, origin: Origin) {
    var found: Int?
    var origin = origin
    for (index, group) in groups.enumerated() {
      guard let handlers = group["hooks"] as? [[String: Any]] else { try refusal() }
      if handlers.contains(where: candidate) {
        guard found == nil,
          let matched = Origin.allCases.first(where: {
            NSDictionary(dictionary: group).isEqual(to: self.group(origin: $0))
          })
        else { try refusal() }
        origin = matched
        found = index
      }
    }
    return (found, origin)
  }

  static func diff(_ old: String, _ new: String) throws -> String {
    let before = try owned(old), after = try owned(new)
    return
      (before.filter { !after.contains($0) }.map { "-" + $0 }
      + after.filter { !before.contains($0) }.map { "+" + $0 }).joined(separator: "\n")
  }

  private static func owned(_ text: String) throws -> [String] {
    if text.isEmpty { return [] }
    let root = try AgentJSON.object(text)
    let hooks = root["hooks"] as? [String: Any] ?? [:]
    let groups = hooks["SessionStart"] as? [[String: Any]] ?? []
    return try groups.filter { ($0["hooks"] as? [[String: Any]] ?? []).contains(where: candidate) }
      .map { try json(["SessionStart": $0]) }
  }

  private static func candidate(_ handler: [String: Any]) -> Bool {
    handler["statusMessage"] as? String == label
      || (handler["command"] as? String)?.contains(marker) == true
  }

  private static func group(origin: Origin) -> [String: Any] {
    let origin = origin.rawValue
    let digest = AgentInstallPlan.hash(Data(("SessionStart:" + origin).utf8))
    return [
      "hooks": [
        [
          "type": "command",
          "command": "silta agents session-start " + marker + origin + ":" + digest,
          "timeout": 2, "statusMessage": label,
        ]
      ]
    ]
  }

  private static func json(_ value: Any) throws -> String {
    guard
      let text = String(
        data: try JSONSerialization.data(
          withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
        encoding: .utf8)
    else { throw TaskError.input }
    return text
  }
}
