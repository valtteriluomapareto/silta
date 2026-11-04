import Foundation

/// Transaction-local policy with independent typed reads. Only absent keys default.
/// Unrelated settings are left undecoded, including values written by newer binaries.
struct WorkspaceSettings: Sendable {
  enum ReviewGate: String, CaseIterable, Sendable {
    case none, any, human
  }

  enum Proposals: String, CaseIterable, Sendable {
    case triage, ask
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case proposals
    case reviewGate = "review_gate"
    case archiveAfterDays = "archive_after_days"
    case staleDays = "stale_days"
  }

  static let defaultArchiveAfterDays = 14

  private let workspace: String
  let json: String

  init(workspace: String, json: String) {
    self.workspace = workspace
    self.json = json
  }

  var reviewGate: ReviewGate {
    get throws {
      let word: String = try value(.reviewGate, default: ReviewGate.none.rawValue)
      guard let gate = ReviewGate(rawValue: word) else {
        throw WorkspaceError.unknownSetting(
          workspace, key: "review_gate", value: try WorkspaceConfig.json(Self.masked(word)))
      }
      return gate
    }
  }

  var proposals: Proposals {
    get throws {
      let word: String = try value(.proposals, default: Proposals.triage.rawValue)
      guard let policy = Proposals(rawValue: word) else {
        throw WorkspaceError.unknownSetting(
          workspace, key: "proposals", value: try WorkspaceConfig.json(Self.masked(word)))
      }
      return policy
    }
  }

  var archiveAfterDays: Int {
    get throws { try days(.archiveAfterDays, default: Self.defaultArchiveAfterDays) }
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
    let document: Any
    do {
      document = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
    } catch {
      throw WorkspaceError.setting(workspace, key: "settings", value: "\"[REDACTED:invalid-json]\"")
    }
    guard let values = document as? [String: Any] else {
      throw WorkspaceError.setting(
        workspace, key: "settings", value: try WorkspaceConfig.json(Self.masked(document)))
    }
    guard let raw = values[key.rawValue] else { return fallback }
    do {
      let bytes = try JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed)
      return try JSONDecoder().decode(T.self, from: bytes)
    } catch {
      throw WorkspaceError.setting(
        workspace, key: key.rawValue, value: try WorkspaceConfig.json(Self.masked(raw)))
    }
  }

  static func masked(_ value: Any) -> Any {
    if let object = value as? [String: Any] {
      return Dictionary(
        object.map { key, value in
          let safeKey = SecretGuard.redacted(key)
          if ["secret", "api_token"].contains(key.lowercased()) {
            return (safeKey, "[REDACTED:credential]" as Any)
          }
          let context = key + "=" + (value as? String ?? "stored-value")
          let valueStart = context.index(context.startIndex, offsetBy: key.count + 1)
          if let match = SecretGuard.matches(in: context).first(where: {
            $0.range.lowerBound < valueStart
          }) {
            return (safeKey, "[REDACTED:\(match.rule)]" as Any)
          }
          return (safeKey, masked(value))
        }, uniquingKeysWith: { _, _ in "[REDACTED:duplicate-key]" as Any })
    }
    if let array = value as? [Any] { return array.map(masked) }
    if let text = value as? String { return SecretGuard.redacted(text) }
    return value
  }
}
