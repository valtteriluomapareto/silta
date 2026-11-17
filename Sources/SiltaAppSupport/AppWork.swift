/// Current human attention, retaining the core's age policy and pagination.
public struct AppWork: Equatable, Sendable {
  /// Up to twelve current inbox entries, in core order.
  public let items: [AppAttention]
  /// Additional eligible inbox entries beyond the cap.
  public let remaining: Int
  /// Core command for reading the omitted entries.
  public let moreCommand: String?
  /// Distinct review tasks from the board's task-list read.
  public let reviews: [AppTask]
  /// Individual actionable entries, including omitted inbox entries and review tasks.
  public var waitingCount: Int { items.count + remaining + reviews.count }
}
