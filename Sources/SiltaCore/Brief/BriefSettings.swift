import Foundation

/// Typed non-default settings, with independently bounded diagnostics for unsupported keys.
package struct BriefSettings: Encodable, Sendable {
  var proposals: String?
  var reviewGate: String?
  var archiveAfterDays: Int?
  var staleDays: Int?
  var text = ""
  var warnings: [OutputWarning] = []

  enum CodingKeys: String, CodingKey {
    case proposals, reviewGate = "review_gate"
    case archiveAfterDays = "archive_after_days", staleDays = "stale_days"
  }

  init(_ settings: WorkspaceSettings, workspace: String) {
    do {
      guard
        let raw = try JSONSerialization.jsonObject(with: Data(settings.json.utf8)) as? [String: Any]
      else { throw StorageError.corrupt }
      let defaults = WorkspaceSettings(workspace: workspace, json: "{}")
      let known = WorkspaceSettings.CodingKeys.allCases.map(\.rawValue)
      var items: [String] = []
      var unsupported: [String] = []
      for name in known + raw.keys.filter({ !known.contains($0) }).sorted() {
        guard let value = raw[name] else { continue }
        if let key = WorkspaceSettings.CodingKeys(rawValue: name) {
          do {
            if let item = try read(key, from: settings, defaults: defaults) {
              items.append("\(name): \(item.value) (\(item.gloss))")
            }
          } catch {
            warn(name: name, value: value, workspace: workspace)
            unsupported.append(name)
          }
        } else {
          warn(name: name, value: value, workspace: workspace)
          unsupported.append(name)
        }
      }
      text = items.isEmpty ? "" : "settings: " + items.joined(separator: "; ") + "\n"
      text += Self.hint(unsupported)
    } catch {
      warn(name: "settings", value: "[invalid settings document]", workspace: workspace)
      text = Self.hint(["settings"])
    }
  }

  private static func hint(_ names: [String]) -> String {
    guard !names.isEmpty else { return "" }
    let shown = names.prefix(8).map { TaskError.shown(String($0.prefix(40))) }
    let more = names.count > 8 ? ", +\(names.count - 8) keys" : ""
    return "settings unsupported: " + shown.joined(separator: ", ") + more + " (ask the human)\n"
  }

  private mutating func warn(name: String, value: Any, workspace: String) {
    let preview: String
    do { preview = try WorkspaceConfig.json(WorkspaceSettings.masked([name: value])) } catch {
      preview = "[unsupported value]"
    }
    let bounded = String(preview.prefix(160)) + (preview.count > 160 ? "…" : "")
    warnings.append(
      .init(
        code: "setting_unsupported",
        message:
          "Unsupported setting \(TaskError.shown(String(name.prefix(40)))): \(bounded); inspect silta --ws "
          + shellWord(workspace) + " ws show."))
  }

  private mutating func read(
    _ key: WorkspaceSettings.CodingKeys,
    from settings: WorkspaceSettings, defaults: WorkspaceSettings
  ) throws -> (value: String, gloss: String)? {
    switch key {
    case .proposals:
      let typed = try settings.proposals
      guard typed != (try defaults.proposals) else { return nil }
      proposals = typed.rawValue
      return (typed.rawValue, typed.gloss)
    case .reviewGate:
      let typed = try settings.reviewGate
      guard typed != (try defaults.reviewGate) else { return nil }
      reviewGate = typed.rawValue
      return (typed.rawValue, typed.gloss)
    case .archiveAfterDays:
      let typed = try settings.archiveAfterDays
      guard typed != (try defaults.archiveAfterDays) else { return nil }
      archiveAfterDays = typed
      return (String(typed), "days before closed tasks archive")
    case .staleDays:
      let typed = try settings.staleDays
      guard typed != (try defaults.staleDays) else { return nil }
      staleDays = typed
      return (String(typed), "days before docs are stale")
    }
  }
}
