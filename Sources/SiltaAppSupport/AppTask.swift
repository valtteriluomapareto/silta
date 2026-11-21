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
  /// Acceptance criteria Markdown; empty when none were written.
  public let acceptance: String
  /// Current plan Markdown.
  public let plan: String
  /// Current plan revision.
  public let planRevision: Int
  /// Parsed top-level checkboxes.
  public let steps: [AppPlanStep]
  /// Parent task reference, for a subtask.
  public let parent: String?
  /// Read-only external tracker reference, for a promoted task.
  public let externalRef: String?
  /// Stored UTC day to revisit the blockers.
  public let followUpAt: String?
  /// What a blocked task waits on; nil unless the task is blocked.
  public let waiting: AppWaiting?
  /// Recorded completion or drop result Markdown.
  public let result: String?
  /// Commit recorded at completion.
  public let doneSHA: String?
  /// Branch recorded at completion.
  public let doneBranch: String?
  /// Whether the worktree had uncommitted changes at completion.
  public let doneDirty: Bool?
  /// Current claimant, including its session.
  public let claimedBy: String?
  /// UTC claim timestamp.
  public let claimedAt: String?
  /// The live handoff comment that released the last claim, when it still exists.
  public let handedOff: String?
  /// A released claim lets the next agent resume this task.
  public let resumeAvailable: Bool
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
  /// Related tasks resolved by a detail read: the parent, subtasks and task blockers.
  /// Board reads leave it empty.
  public let related: [AppTaskSummary]
  /// Discussion as Core's normal read shows it, roots before replies. It can include a
  /// resolved thread: Core keeps the newest handoff even when resolved.
  public let comments: [AppComment]
  /// Posts of the resolved threads Core's normal read hides, roots before replies.
  public let resolvedComments: [AppComment]

  /// Subtasks among the related tasks, in reference order.
  public var subtasks: [AppTaskSummary] { related.filter { $0.parent == ref } }

  /// The related task with this reference, if the detail read found it.
  public func related(_ ref: String) -> AppTaskSummary? { related.first { $0.ref == ref } }
}

/// What a blocked task waits on, as Core computes it at read time.
public struct AppWaiting: Equatable, Sendable {
  /// Current blockers: task references, `ext:` parties or masked URLs.
  public let on: [String]
  /// Whole days since this blocked episode began.
  public let ageDays: Int
  /// The latest reason, with credential matches masked.
  public let why: String
  /// Every blocker is a completed task, so the task can be unblocked.
  public let ready: Bool
  /// Dropped blocker tasks, which call for a re-plan.
  public let dropped: [String]

  /// The task reference a `task:` blocker names; nil for parties and URLs.
  public static func taskRef(_ blocker: String) -> String? {
    blocker.hasPrefix("task:") ? String(blocker.dropFirst("task:".count)) : nil
  }
}

/// A related task's identity and state, for rows that name it.
public struct AppTaskSummary: Equatable, Sendable {
  /// Canonical task reference.
  public let ref: String
  /// Task title.
  public let title: String
  /// Stored task status.
  public let status: String
  /// Parent task reference, if any.
  public let parent: String?
}

extension AppTask {
  init(
    _ task: TaskDetails, submission: TaskEvent? = nil, resolved: [CommentDetails] = [],
    related: [TaskDetails] = []
  ) {
    self.init(
      ref: task.ref, title: task.title, status: task.status, app: task.app,
      priority: task.priority, description: task.description, acceptance: task.acceptance,
      plan: task.plan, planRevision: task.planRev,
      steps: MarkdownPlan.checkboxes(task.plan).map { AppPlanStep(title: $0.title, done: $0.done) },
      parent: task.parent, externalRef: task.externalRef, followUpAt: task.followUpAt,
      waiting: task.waiting.map {
        AppWaiting(
          on: $0.on, ageDays: $0.ageDays, why: $0.why, ready: $0.ready, dropped: $0.dropped)
      },
      result: task.result, doneSHA: task.doneSHA, doneBranch: task.doneBranch,
      doneDirty: task.doneDirty, claimedBy: task.claimedBy, claimedAt: task.claimedAt,
      handedOff: task.handedOff, resumeAvailable: task.resumeAvailable, branch: task.branch,
      worktree: task.worktree, createdBy: task.createdBy, createdAt: task.createdAt,
      updatedAt: task.updatedAt, closedAt: task.closedAt,
      submission: submission.map {
        AppSubmission(actor: SecretGuard.redacted($0.actor), at: SecretGuard.redacted($0.at))
      },
      links: task.links.map { AppTaskLink(rel: $0.rel, target: $0.displayTarget) },
      related: related.map {
        AppTaskSummary(ref: $0.ref, title: $0.title, status: $0.status, parent: $0.parent)
      },
      comments: (task.comments ?? []).map(AppComment.init),
      resolvedComments: resolved.map(AppComment.init))
  }
}

extension AppComment {
  init(_ post: CommentDetails) {
    self.init(
      ref: post.ref, kind: post.kind, actor: post.actor, body: post.body,
      createdAt: post.createdAt, replyTo: post.replyTo, accepted: post.accepted,
      deleted: post.deleted, resolvedAt: post.resolvedAt, resolvedBy: post.resolvedBy,
      mentions: post.mentions, answered: post.answered)
  }
}

/// A displayed task link with its recorded relationship preserved.
public struct AppTaskLink: Equatable, Sendable {
  /// Recorded relationship, such as `about` or `cites`.
  public let rel: String
  /// Masked canonical target reference.
  public let target: String
}
