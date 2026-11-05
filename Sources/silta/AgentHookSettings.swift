import Foundation
import SiltaCore

/// Only an exact sealed hook group is owned; unknown settings stay as JSON values.
enum AgentHookSettings {
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
    let ownership = try ownership(groups, created: !existed, refusal: refusal)
    let found = ownership.index, created = ownership.created
    if uninstall {
      guard let found else { return original }
      groups.remove(at: found)
    } else {
      if found != nil { return original }
      groups.append(group(created: created))
    }
    if groups.isEmpty {
      hooks.removeValue(forKey: "SessionStart")
    } else {
      hooks["SessionStart"] = groups
    }
    if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
    if uninstall, created, root.isEmpty { return "" }
    return try json(root) + "\n"
  }

  private static func ownership(
    _ groups: [[String: Any]], created: Bool,
    refusal: () throws -> Never
  ) throws -> (index: Int?, created: Bool) {
    var found: Int?
    var created = created
    for (index, group) in groups.enumerated() {
      guard let handlers = group["hooks"] as? [[String: Any]] else { try refusal() }
      if handlers.contains(where: candidate) {
        guard found == nil else { try refusal() }
        if NSDictionary(dictionary: group).isEqual(to: self.group(created: true)) {
          created = true
        } else if NSDictionary(dictionary: group).isEqual(to: self.group(created: false)) {
          created = false
        } else {
          try refusal()
        }
        found = index
      }
    }
    return (found, created)
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

  private static func group(created: Bool) -> [String: Any] {
    let origin = created ? "new" : "keep"
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
