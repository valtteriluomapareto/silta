/// Recorded attribution for the most recent submission to review.
public struct AppSubmission: Equatable, Sendable {
  /// Masked identity of the actor who submitted the task.
  public let actor: String
  /// Recorded UTC submission instant; subsequent edits do not change it.
  public let at: String
}
