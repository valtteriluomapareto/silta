import Foundation
import Yams

/// The Appendix A editing view, validated before any database changes.
package struct WorkspaceConfig {
  let root: Node

  static let fields: [String: [String]] = [
    "workspace": ["slug", "name", "task_prefix"],
    "settings": WorkspaceSettings.CodingKeys.allCases.map(\.rawValue),
    "repos": ["slug", "remote"],
    "apps": ["slug", "repo", "ref", "prod_ref", "subpath", "summary", "lifecycle"],
    "environments": ["app", "name", "url"],
    "edges": ["from", "to", "kind", "summary", "code"],
    "topics": ["slug", "aliases"],
    "sources": ["kind", "root", "include", "exclude"],
  ]

  static let required: [String: [String]] = [
    "workspace": ["slug", "name", "task_prefix"], "repos": ["slug"],
    "apps": ["slug", "repo", "ref"], "environments": ["app", "name"],
    "edges": ["from", "to", "kind", "summary"], "topics": ["slug"],
    "sources": ["kind", "root", "include"],
  ]

  /// Parses YAML and collects key, type, identity and relationship problems with source lines.
  package static func parse(_ yaml: String) throws -> WorkspaceConfig {
    let root: Node
    do {
      guard let document = try Yams.compose(yaml: yaml) else {
        throw WorkspaceError.invalid(["line 1: expected a workspace mapping"])
      }
      root = document
    } catch let error as WorkspaceError {
      throw error
    } catch let error as YamlError {
      let line: Int
      switch error {
      case .scanner(_, _, let mark, _), .parser(_, _, let mark, _), .composer(_, _, let mark, _):
        line = mark.line
      case .duplicatedKeysInMapping(_, let context): line = context.mark.line
      default: line = 1
      }
      throw WorkspaceError.invalid(["line \(line): invalid YAML"])
    } catch {
      throw WorkspaceError.invalid(["line 1: invalid YAML"])
    }
    let config = WorkspaceConfig(root: root)
    let problems = config.validate()
    guard problems.isEmpty else { throw WorkspaceError.invalid(problems) }
    return config
  }

  var slug: String {
    root["workspace"]?["slug"]?.string ?? ""
  }

  func rows(_ section: String) -> [Node] {
    root[section]?.array() ?? []
  }

  private func validate() -> [String] {
    var validation = WorkspaceValidation(root: root)
    validation.run()
    return validation.problems
  }

  static func normalize(_ alias: String) -> String {
    alias.precomposedStringWithCanonicalMapping.lowercased()
  }

  static func identity(_ node: Node, section: String) -> String {
    let keys: [String]
    switch section {
    case "services": return node.string ?? ""
    case "environments": keys = ["app", "name"]
    case "edges": keys = ["from", "to", "kind"]
    case "sources": keys = ["kind", "root"]
    default: keys = ["slug"]
    }
    return keys.map { node[$0]?.string ?? "" }.joined(separator: "\n")
  }

  /// The identifier shape shared by workspace, repo, app and topic slugs and task prefixes.
  package static func isValidIdentifier(_ value: String) -> Bool {
    value.wholeMatch(of: /[A-Za-z0-9]+(?:[A-Za-z0-9_-]*[A-Za-z0-9])?/) != nil
  }

  fileprivate static func suggestion(_ value: String, among candidates: [String]) -> String {
    let ranked = candidates.sorted().map { ($0, distance(value, $0)) }
    guard let best = ranked.min(by: { $0.1 < $1.1 }), best.1 <= 2 else { return "" }
    return "; did you mean \(best.0)?"
  }

  private static func distance(_ lhs: String, _ rhs: String) -> Int {
    var previous = Array(0...rhs.count)
    for (i, left) in lhs.enumerated() {
      var current = [i + 1]
      for (j, right) in rhs.enumerated() {
        current.append(
          min(current[j] + 1, previous[j + 1] + 1, previous[j] + (left == right ? 0 : 1)))
      }
      previous = current
    }
    return previous.last ?? 0
  }
}

private struct WorkspaceValidation {
  let root: Node

  var problems: [String] = []

  mutating func problem(_ node: Node, _ message: String) {
    let line = node.mark?.line ?? 1
    let text = message.replacingOccurrences(of: "\n", with: " ")
    problems.append("line \(line): \(text)")
  }

  func rows(_ section: String) -> [Node] {
    root[section]?.array() ?? []
  }

  mutating func run() {
    keys(root, allowed: Array(WorkspaceConfig.fields.keys) + ["services"])
    if root["workspace"] == nil { problem(root, "workspace is required") }
    validateSections()
    validateIdentities()
    validateReferences()
    validateAliases()
  }

  mutating func keys(_ node: Node, allowed: [String]) {
    guard let mapping = node.mapping else {
      problem(node, "expected a mapping")
      return
    }
    for (key, _) in mapping {
      let name = key.string ?? ""
      if !allowed.contains(name) {
        problem(key, "unknown key \(name)\(WorkspaceConfig.suggestion(name, among: allowed))")
      }
    }
  }

  mutating func validateSections() {
    for section in WorkspaceConfig.fields.keys.sorted() {
      guard let sectionNode = root[section] else { continue }
      let entries: [Node]
      if section == "workspace" || section == "settings" {
        entries = [sectionNode]
      } else {
        if sectionNode.sequence == nil { problem(sectionNode, "\(section) must be a list") }
        entries = sectionNode.array()
      }
      for entry in entries { validateEntry(entry, section: section) }
    }
    if let services = root["services"] {
      if services.sequence == nil { problem(services, "services must be a list") }
      for node in services.array() where node.tag != Tag(.str) || (node.string ?? "").isEmpty {
        problem(node, "service must be a nonempty slug")
      }
    }
  }

  mutating func validateEntry(_ entry: Node, section: String) {
    keys(entry, allowed: WorkspaceConfig.fields[section] ?? [])
    for key in WorkspaceConfig.required[section] ?? [] where entry[key] == nil {
      problem(entry, "\(section).\(key) is required")
    }
    validateValues(entry)
    for key in ["slug", "task_prefix"] {
      if let value = entry[key]?.string, !WorkspaceConfig.isValidIdentifier(value) {
        problem(entry[key] ?? entry, "invalid \(key)")
      }
    }
    if section == "apps", entry["slug"]?.string == TaskDraft.noneApp {
      problem(entry["slug"] ?? entry, "invalid slug: none is reserved for non-code work")
    }
    if let lifecycle = entry["lifecycle"]?.string,
      !["active", "legacy", "dead"].contains(lifecycle)
    {
      problem(entry["lifecycle"] ?? entry, "invalid lifecycle")
    }
    if section == "sources", let kind = entry["kind"]?.string,
      !["notes", "repo-docs"].contains(kind)
    {
      problem(entry, "source kind must be notes or repo-docs")
    }
  }

  mutating func validateValues(_ entry: Node) {
    for (keyNode, value) in entry.mapping ?? Node.Mapping([]) {
      let key = keyNode.string ?? ""
      if ["code", "aliases", "include", "exclude"].contains(key) {
        if value.sequence == nil || value.array().contains(where: { $0.tag != Tag(.str) }) {
          problem(value, "\(key) must be a list of strings")
        }
      } else if ["archive_after_days", "stale_days"].contains(key) {
        if value.int == nil || (value.int ?? -1) < 0 {
          problem(value, "\(key) must be a nonnegative integer")
        }
      } else if key == "review_gate" || key == "proposals" {
        validatePolicy(value, key: key)
      } else if value.tag != Tag(.str) || (value.string ?? "").isEmpty {
        problem(value, "\(key) must be a nonempty string")
      }
    }
  }

  mutating func validatePolicy(_ value: Node, key: String) {
    let gate = key == "review_gate"
    let words =
      gate
      ? WorkspaceSettings.ReviewGate.allCases.map(\.rawValue)
      : WorkspaceSettings.Proposals.allCases.map(\.rawValue)
    let accepted =
      gate ? "review_gate must be none, any or human" : "proposals must be triage or ask"
    let text = value.scalar?.string ?? ""
    if ["on", "off", "yes", "no", "true", "false", "y", "n"].contains(text.lowercased()) {
      let gloss =
        gate
        ? WorkspaceSettings.ReviewGate.allCases.map { "\($0.rawValue): \($0.gloss)" }.joined(
          separator: "; ") + "."
        : WorkspaceSettings.Proposals.allCases.map { "\($0.rawValue): \($0.gloss)" }.joined(
          separator: "; ") + "."
      problem(value, accepted + ". " + gloss + " Ask the human which policy to use.")
    } else if value.tag != Tag(.str) || text.isEmpty {
      problem(value, accepted)
    } else if !words.contains(text) {
      let hint = WorkspaceConfig.suggestion(text, among: words)
      problem(
        value,
        accepted + hint + (hint.isEmpty ? "." : "")
          + " Ask the human which policy to use.")
    }
  }

  mutating func validateIdentities() {
    for section in ["repos", "apps", "services", "environments", "edges", "topics", "sources"] {
      var seen: Set<String> = []
      for node in rows(section) {
        let identity = WorkspaceConfig.identity(node, section: section)
        if !seen.insert(identity).inserted {
          problem(node, "duplicate \(section) identity \(identity)")
        }
      }
    }
  }

  mutating func reference(_ entry: Node, _ key: String, _ section: String, prefix: String = "") {
    guard let value = entry[key]?.string else { return }
    let target = prefix.isEmpty ? value : String(value.dropFirst(prefix.count))
    let known = rows(section).compactMap {
      section == "services" ? $0.string : $0["slug"]?.string
    }
    if !known.contains(target) {
      problem(
        entry[key] ?? entry,
        "unknown \(section) slug \(target)\(WorkspaceConfig.suggestion(target, among: known))")
    }
  }

  mutating func validateReferences() {
    var primary: Set<String> = []
    for app in rows("apps") {
      reference(app, "repo", "repos")
      if app["subpath"] == nil {
        let key = [app["repo"]?.string ?? "", app["ref"]?.string ?? ""].joined(separator: "\n")
        if !primary.insert(key).inserted { problem(app, "duplicate primary repo/ref") }
      }
    }
    for entry in rows("environments") { reference(entry, "app", "apps") }
    for entry in rows("edges") {
      reference(entry, "from", "apps")
      if entry["to"]?.string?.hasPrefix("service:") == true {
        reference(entry, "to", "services", prefix: "service:")
      } else {
        reference(entry, "to", "apps")
      }
    }
  }

  mutating func validateAliases() {
    var aliases: Set<String> = []
    for topic in rows("topics") {
      for alias in topic["aliases"]?.array() ?? [] {
        let normalized = WorkspaceConfig.normalize(alias.string ?? "")
        if !aliases.insert(normalized).inserted { problem(alias, "duplicate alias \(normalized)") }
      }
    }
  }
}
