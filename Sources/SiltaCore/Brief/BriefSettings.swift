import Foundation

/// Open JSON object of non-default settings; unsupported keys retain masked raw values.
package struct BriefSettings: Encodable, Sendable {
  let values: [String: BriefSettingValue]
  let text: String
  let warnings: [OutputWarning]

  init(_ settings: WorkspaceSettings, workspace: String) {
    do {
      let document = try JSONSerialization.jsonObject(with: Data(settings.json.utf8))
      guard let object = document as? [String: Any] else { throw StorageError.unavailable }
      let raw = try JSONDecoder().decode(
        [String: BriefSettingValue].self,
        from: JSONSerialization.data(withJSONObject: WorkspaceSettings.masked(object)))
      let defaults = WorkspaceSettings(workspace: workspace, json: "{}")
      var values: [String: BriefSettingValue] = [:]
      var items: [String] = []
      var warnings: [OutputWarning] = []
      let known = WorkspaceSettings.CodingKeys.allCases.map(\.rawValue)
      for name in known + raw.keys.filter({ !known.contains($0) }).sorted() {
        guard let value = raw[name] else { continue }
        do {
          guard let key = WorkspaceSettings.CodingKeys(rawValue: name) else {
            throw StorageError.unavailable
          }
          let typed = try key.value(in: settings)
          guard typed != (try key.value(in: defaults)) else { continue }
          values[name] = typed
          items.append("\(name): \(typed.text) (\(try key.gloss(in: settings)))")
        } catch {
          values[name] = value
          items.append("\(TaskError.shown(name)): \(value.text)")
          warnings.append(
            OutputWarning(
              code: "setting_unsupported",
              message: "Unsupported setting \(TaskError.shown(name)); inspect silta ws show "
                + shellWord(workspace) + "."))
        }
      }
      self.values = values
      self.text = items.isEmpty ? "" : "settings: " + items.joined(separator: "; ") + "\n"
      self.warnings = warnings
    } catch {
      values = ["_invalid": .string("[invalid settings document]")]
      text = "settings: [invalid settings document]\n"
      warnings = [
        .init(
          code: "setting_unsupported",
          message: "Invalid settings document; inspect silta ws show " + shellWord(workspace) + ".")
      ]
    }
  }

  package func encode(to encoder: any Encoder) throws { try values.encode(to: encoder) }
}
