import Foundation

/// Input for recording why a task cannot proceed. No message is delivered.
package struct TaskBlock: Sendable {
  /// Task, ext:party or url:http(s) references to add to the current blockers.
  package var on: [String] = []

  /// A UTC YYYY-MM-DD day or nonnegative Nd interval; nil means seven days.
  package var followUp: String?

  /// The nonblank reason to record.
  package var why: String

  /// Retains matching credentials only with human approval.
  package var allowSecret = false

  /// Starts with a reason and no named prerequisite.
  package init(why: String) {
    self.why = why
  }

  /// Keeps named blockers and follow-up in body-free recovery and audit commands.
  /// Credential-bearing targets require manual replacement, never a changed URL identity.
  package func command(_ ref: String) -> String {
    var value = "silta task block " + shellWord(SecretGuard.redacted(ref))
    for raw in on {
      let safe = Self.party(raw) != nil || SecretGuard.matches(in: raw).isEmpty
      value += " --on " + shellWord(safe ? raw : "<blocker-ref>")
    }
    if let followUp { value += " --follow-up " + shellWord(SecretGuard.redacted(followUp)) }
    return value
  }

  static func party(_ raw: String) -> String? {
    guard raw.hasPrefix("ext:") else { return nil }
    let value = String(raw.dropFirst(4))
    guard value.utf8.count <= 64,
      value.wholeMatch(of: /[a-z0-9](?:[a-z0-9-]*[a-z0-9])?/) != nil
    else { return nil }
    return value
  }
}

/// The immutable body of a block event. References use task UIDs or external strings.
struct TaskBlockEvent: Codable {
  let on: [String]

  let followUp: String

  let why: String

  enum CodingKeys: String, CodingKey {
    case on, why
    case followUp = "follow_up"
  }

  func encoded() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let text = String(bytes: try encoder.encode(self), encoding: .utf8) else {
      throw StorageError.unavailable
    }
    return text
  }

  static func decode(_ body: String) throws -> Self {
    do { return try JSONDecoder().decode(Self.self, from: Data(body.utf8)) } catch {
      throw StorageError.unavailable
    }
  }

  func safeBody() throws -> String {
    try Self(
      on: on.map { $0.hasPrefix("url:") ? SecretGuard.redacted($0) : $0 },
      followUp: followUp, why: SecretGuard.redacted(why)
    ).encoded()
  }
}
