import Foundation

/// Transaction-local policy with independent typed reads. Only absent keys default.
/// Unrelated settings are left undecoded, including values written by newer binaries.
struct WorkspaceSettings: Sendable {
  enum ReviewGate: String, Decodable, CaseIterable, Sendable {
    case none, any, human
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case reviewGate = "review_gate"
    case archiveAfterDays = "archive_after_days"
    case staleDays = "stale_days"
  }

  private let workspace: String
  private let json: String

  init(workspace: String, json: String) {
    self.workspace = workspace
    self.json = json
  }

  var reviewGate: ReviewGate {
    get throws { try value(.reviewGate, default: .none) }
  }

  var archiveAfterDays: Int {
    get throws { try days(.archiveAfterDays, default: 14) }
  }

  var staleDays: Int {
    get throws { try days(.staleDays, default: 90) }
  }

  private func days(_ key: CodingKeys, default fallback: Int) throws -> Int {
    let count: Int = try value(key, default: fallback)
    guard count >= 0 else {
      throw WorkspaceError.setting(workspace, key: key.rawValue, value: String(count))
    }
    return count
  }

  private func value<T: Decodable>(_ key: CodingKeys, default fallback: T) throws -> T {
    var stored = json
    do {
      guard
        let values = try JSONSerialization.jsonObject(
          with: Data(json.utf8), options: .fragmentsAllowed) as? [String: Any]
      else { throw WorkspaceError.setting(workspace, key: key.rawValue, value: stored) }
      guard let raw = values[key.rawValue] else { return fallback }
      let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
      let bytes = try JSONSerialization.data(withJSONObject: raw, options: options)
      let displayed: Data
      if let text = raw as? String {
        displayed = try JSONSerialization.data(
          withJSONObject: SecretGuard.redacted(text), options: options)
      } else {
        displayed = bytes
      }
      guard let preview = String(data: displayed, encoding: .utf8) else {
        throw WorkspaceError.setting(workspace, key: key.rawValue, value: stored)
      }
      stored = preview
      return try JSONDecoder().decode(T.self, from: bytes)
    } catch {
      throw WorkspaceError.setting(workspace, key: key.rawValue, value: stored)
    }
  }
}
