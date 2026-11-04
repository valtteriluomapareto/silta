/// Effective workspace policy. Only absent keys use defaults; unknown keys are ignored.
/// This read value is never encoded into the stored-only configuration editing view.
struct WorkspaceSettings: Decodable, Sendable {
  enum ReviewGate: String, Decodable, CaseIterable, Sendable {
    case none, any, human
  }

  let reviewGate: ReviewGate
  let archiveAfterDays: Int
  let staleDays: Int

  private enum CodingKeys: String, CodingKey {
    case reviewGate = "review_gate"
    case archiveAfterDays = "archive_after_days"
    case staleDays = "stale_days"
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    reviewGate =
      try values.contains(.reviewGate) ? values.decode(ReviewGate.self, forKey: .reviewGate) : .none
    archiveAfterDays =
      try values.contains(.archiveAfterDays)
      ? values.decode(Int.self, forKey: .archiveAfterDays) : 14
    staleDays = try values.contains(.staleDays) ? values.decode(Int.self, forKey: .staleDays) : 90
  }
}
