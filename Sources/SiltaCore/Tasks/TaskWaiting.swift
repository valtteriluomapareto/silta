/// The current blocking episode, computed without changing storage.
package struct TaskWaiting: Encodable, Equatable, Sendable {
  /// Current blocker references, with sensitive URL content masked.
  package let on: [String]

  /// Whole elapsed days since this episode began.
  package let ageDays: Int

  /// The latest reason, with credential matches masked.
  package let why: String

  /// Whether every blocker is an unpromoted, completed task.
  package let ready: Bool

  /// Dropped prerequisites that require re-planning.
  package let dropped: [String]

  enum CodingKeys: String, CodingKey {
    case on, why, ready, dropped
    case ageDays = "age_days"
  }
}

/// A block receipt includes the actual follow-up day and waiting state.
package struct TaskBlockResult: Encodable, Sendable {
  /// The blocked task reference.
  package let ref: String

  /// The resulting task status.
  package let status: String

  /// The persisted UTC follow-up day.
  package let followUpAt: String?

  /// The current blocking episode.
  package let waiting: TaskWaiting?

  /// First-party and secret-redaction diagnostics.
  package let warnings: [OutputWarning]

  enum CodingKeys: String, CodingKey {
    case ref, status, waiting
    case followUpAt = "follow_up_at"
  }
}
