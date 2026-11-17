/// Board values derived from one task-list read.
public struct AppBoard: Equatable, Sendable {
  /// Tasks waiting to start or blocked, retaining their original status.
  public let todo: [AppTask]
  /// Open tasks in progress.
  public let doing: [AppTask]
  /// Tasks submitted for review.
  public let review: [AppTask]
  /// Tasks completed since Monday at 00:00 UTC.
  public let doneThisWeek: [AppTask]
  /// Visible proposals, independent of open counts.
  public let proposals: [AppTask]
  /// All eligible human questions, independent of My work pagination.
  public let questions: [AppAttention]
  /// Visible local open counts by associated app, including blocked tasks.
  public let appOpenCounts: [String: Int]
}
