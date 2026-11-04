/// One diagnostic result. Recovery commands never authorize unrelated repairs.
package struct DoctorCheck: Encodable, Sendable {
  /// Diagnostic severity, encoded as its stable lowercase name.
  package enum Status: String, Encodable, Sendable {
    case pass, warning, fail, skipped
  }

  /// Stable check identifier; identifiers are only added, never renamed.
  package let id: String
  /// The diagnostic result.
  package let status: Status
  /// Body-free explanation of the result.
  package let message: String
  /// At most five distinct commands, in deterministic priority order.
  package let next: [String]
  /// Who may run every command in this check's next list.
  package let nextBy: NextBy
  /// Number of distinct commands omitted after the first five.
  package let nextOmitted: Int

  /// Deduplicates and bounds inspection commands before any output is rendered.
  package init(
    id: String, status: Status, message: String, next: [String] = [], nextBy: NextBy = .agent
  ) {
    self.id = id
    self.status = status
    self.message = message
    self.nextBy = nextBy
    var seen: Set<String> = []
    let commands = next.filter { seen.insert($0).inserted }
    self.next = Array(commands.prefix(5))
    nextOmitted = max(0, commands.count - 5)
  }

  enum CodingKeys: String, CodingKey {
    case id, status, message, next
    case nextBy = "next_by"
    case nextOmitted = "next_omitted"
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(status, forKey: .status)
    try container.encode(message, forKey: .message)
    try container.encode(next, forKey: .next)
    try container.encode(nextBy.rawValue, forKey: .nextBy)
    try container.encode(nextOmitted, forKey: .nextOmitted)
  }
}
