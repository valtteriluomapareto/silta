import Foundation
import SiltaCore

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
  /// Most recent recorded submission; nil means no submission event was recorded.
  public let submission: AppSubmission?
  /// Masked task links retaining their relationship to the target.
  public let links: [AppTaskLink]
  /// Discussion included when reading task detail.
  public let comments: [AppComment]
}

extension AppTask {
  init(_ task: TaskDetails, submission: TaskEvent? = nil) {
    self.init(
      ref: task.ref, title: task.title, status: task.status, app: task.app,
      priority: task.priority, description: task.description, plan: task.plan,
      planRevision: task.planRev,
      steps: MarkdownPlan.checkboxes(task.plan).map { AppPlanStep(title: $0.title, done: $0.done) },
      claimedBy: task.claimedBy, claimedAt: task.claimedAt, branch: task.branch,
      worktree: task.worktree, createdBy: task.createdBy, createdAt: task.createdAt,
      updatedAt: task.updatedAt, closedAt: task.closedAt,
      submission: submission.map {
        AppSubmission(actor: SecretGuard.redacted($0.actor), at: SecretGuard.redacted($0.at))
      },
      links: task.links.map { AppTaskLink(rel: $0.rel, target: $0.displayTarget) },
      comments: (task.comments ?? []).map {
        AppComment(
          ref: $0.ref, kind: $0.kind, actor: $0.actor, body: $0.body,
          createdAt: $0.createdAt, replyTo: $0.replyTo)
      })
  }
}

/// A displayed task link with its recorded relationship preserved.
public struct AppTaskLink: Equatable, Sendable {
  /// Recorded relationship, such as `about` or `cites`.
  public let rel: String
  /// Masked canonical target reference.
  public let target: String
}
