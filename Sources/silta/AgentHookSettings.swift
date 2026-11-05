import Foundation
import SiltaCore

/// Only exact sealed hook groups are owned; unknown settings stay as JSON values.
enum AgentHookSettings {
  private enum Origin: String, CaseIterable { case file = "new", hooks, event, keep }
  private static let events = ["SessionStart", "Stop"]

  static func edit(
    _ original: String, existed: Bool, uninstall: Bool, stop: Bool,
    refusal: () throws -> Never
  ) throws -> String {
    var root: [String: Any]
    do { root = existed ? try AgentJSON.object(original) : [:] } catch { try refusal() }
    guard root["hooks"] == nil || root["hooks"] is [String: Any] else { try refusal() }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    let origins = events.flatMap { event in
      (hooks[event] as? [[String: Any]] ?? []).compactMap { matched($0, event: event) }
    }
    let newFile = !existed || origins.contains(.file)
    let newHooks = newFile || root["hooks"] == nil || origins.contains(.hooks)
    var changed = false
    for event in (uninstall || stop ? events : ["SessionStart"]) {
      guard hooks[event] == nil || hooks[event] is [[String: Any]] else { try refusal() }
      var groups = hooks[event] as? [[String: Any]] ?? []
      let initial: Origin =
        hooks[event] != nil ? .keep : newFile ? .file : newHooks ? .hooks : .event
      let ownership = try ownership(groups, event: event, origin: initial, refusal: refusal)
      if uninstall {
        guard let found = ownership.index else { continue }
        groups.remove(at: found)
      } else {
        if ownership.index != nil { continue }
        groups.append(group(event: event, origin: ownership.origin))
      }
      changed = true
      if groups.isEmpty, ownership.origin != .keep {
        hooks.removeValue(forKey: event)
      } else {
        hooks[event] = groups
      }
    }
    guard changed else { return original }
    put(hooks, into: &root, created: newHooks)
    if uninstall, newFile, root.isEmpty { return "" }
    return try json(root) + "\n"
  }

  private static func put(_ hooks: [String: Any], into root: inout [String: Any], created: Bool) {
    if hooks.isEmpty, created { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
  }

  private static func ownership(
    _ groups: [[String: Any]], event: String, origin: Origin,
    refusal: () throws -> Never
  ) throws -> (index: Int?, origin: Origin) {
    var found: Int?
    var origin = origin
    for (index, group) in groups.enumerated() {
      guard let handlers = group["hooks"] as? [[String: Any]] else { try refusal() }
      if handlers.contains(where: { candidate($0, event: event) }) {
        guard found == nil, let matched = matched(group, event: event) else { try refusal() }
        origin = matched
        found = index
      }
    }
    return (found, origin)
  }

  private static func matched(_ value: [String: Any], event: String) -> Origin? {
    Origin.allCases.first {
      NSDictionary(dictionary: value).isEqual(to: group(event: event, origin: $0))
    }
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
    return try events.flatMap { event in
      let groups = hooks[event] as? [[String: Any]] ?? []
      return try groups.filter {
        ($0["hooks"] as? [[String: Any]] ?? []).contains { candidate($0, event: event) }
      }.map { try json([event: $0]) }
    }
  }

  private static func candidate(_ handler: [String: Any], event: String) -> Bool {
    handler["statusMessage"] as? String == "Silta " + event
      || (handler["command"] as? String)?.contains(marker(event)) == true
  }

  private static func marker(_ event: String) -> String {
    "# silta:" + (event == "SessionStart" ? "session-start" : "stop") + ":v1:"
  }

  private static func group(event: String, origin: Origin) -> [String: Any] {
    let origin = origin.rawValue
    let digest = AgentInstallPlan.hash(Data((event + ":" + origin).utf8))
    let command = event == "SessionStart" ? "session-start" : "stop"
    return [
      "hooks": [
        [
          "type": "command",
          "command": "silta agents " + command + " " + marker(event) + origin + ":" + digest,
          "timeout": 2, "statusMessage": "Silta " + event,
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
