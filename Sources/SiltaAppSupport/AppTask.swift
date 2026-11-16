/// Task values shared by board cards, review attention and the inspector.
public struct AppTask: Equatable, Sendable {
  /// Canonical task reference.
  public let ref: String
  /// Task title.
  public let title: String
  /// Stored task status.
  public let status: String
  /// Associated app slug, if any.
  public let app: String?
  /// Priority, with one first.
  public let priority: Int
  /// Task description Markdown.
  public let description: String
  /// Current plan Markdown.
  public let plan: String
  /// Current plan revision.
  public let planRevision: Int
  /// Parsed top-level checkboxes.
  public let steps: [AppPlanStep]
  /// Current claimant, including its session.
  public let claimedBy: String?
  /// UTC claim timestamp.
  public let claimedAt: String?
  /// Recorded worktree branch.
  public let branch: String?
  /// Recorded worktree directory.
  public let worktree: String?
  /// Creating actor identity.
  public let createdBy: String
  /// UTC creation timestamp.
  public let createdAt: String
  /// UTC last task update timestamp.
  public let updatedAt: String
  /// UTC completion timestamp, independent of subsequent edits.
  public let closedAt: String?
  /// Discussion included when reading task detail.
  public let comments: [AppComment]
}
