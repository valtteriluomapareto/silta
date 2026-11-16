/// Board values derived from one task-list read.
public struct AppBoard: Equatable, Sendable {
  /// Open tasks waiting to start.
  public let todo: [AppTask]
  /// Open tasks in progress.
  public let doing: [AppTask]
  /// Tasks submitted for review.
  public let review: [AppTask]
  /// Tasks completed since Monday at 00:00 UTC.
  public let doneThisWeek: [AppTask]
  /// Visible proposals, independent of open counts.
  public let proposedCount: Int
  /// Open counts by associated app.
  public let appOpenCounts: [String: Int]
}
