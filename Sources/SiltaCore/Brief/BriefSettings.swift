import Foundation

/// Typed non-default settings. Unsupported keys are omitted and diagnosed independently.
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
      else { throw StorageError.unavailable }
      var items: [String] = []
      let defaults = WorkspaceSettings(workspace: workspace, json: "{}")
      let known = WorkspaceSettings.CodingKeys.allCases.map(\.rawValue)
      for name in known + raw.keys.filter({ !known.contains($0) }).sorted() {
        do {
          guard let key = WorkspaceSettings.CodingKeys(rawValue: name) else {
            throw StorageError.unavailable
          }
          guard raw[name] != nil else { continue }
          guard let value = try read(key, from: settings, defaults: defaults) else { continue }
          items.append("\(name): \(value) (\(try key.gloss(in: settings)))")
        } catch {
          let preview = try WorkspaceConfig.json(
            WorkspaceSettings.masked([name: raw[name] ?? NSNull()]))
          warnings.append(
            .init(
              code: "setting_unsupported",
              message: "Unsupported setting \(TaskError.shown(preview)); inspect silta --ws "
                + shellWord(workspace) + " ws show."))
        }
      }
      text = items.isEmpty ? "" : "settings: " + items.joined(separator: "; ") + "\n"
    } catch {
      warnings = [
        .init(
          code: "setting_unsupported",
          message: "Invalid settings document; inspect silta --ws " + shellWord(workspace)
            + " ws show.")
      ]
    }
  }
  private mutating func read(
    _ key: WorkspaceSettings.CodingKeys, from settings: WorkspaceSettings,
    defaults: WorkspaceSettings
  ) throws -> String? {
    switch key {
    case .proposals:
      let typed = try settings.proposals
      guard typed != (try defaults.proposals) else { return nil }
      proposals = typed.rawValue
      return typed.rawValue
    case .reviewGate:
      let typed = try settings.reviewGate
      guard typed != (try defaults.reviewGate) else { return nil }
      reviewGate = typed.rawValue
      return typed.rawValue
    case .archiveAfterDays:
      let typed = try settings.archiveAfterDays
      guard typed != (try defaults.archiveAfterDays) else { return nil }
      archiveAfterDays = typed
      return String(typed)
    case .staleDays:
      let typed = try settings.staleDays
      guard typed != (try defaults.staleDays) else { return nil }
      staleDays = typed
      return String(typed)
    }
  }

}
