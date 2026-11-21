public import Foundation
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
  /// What only the detail read resolves: related tasks and each blocker's state. Nil on
  /// board reads, so "none" and "not loaded" stay distinct.
  public let detail: AppTaskDetail?
  /// Discussion as Core's normal read shows it, roots before replies. It can include a
  /// resolved thread: Core keeps the newest handoff even when resolved.
  public let comments: [AppComment]
  /// Posts of the resolved threads Core's normal read hides, roots before replies.
  public let resolvedComments: [AppComment]
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
}

/// What the detail read adds to a task: its relatives and its blockers' states.
public struct AppTaskDetail: Equatable, Sendable {
  /// The parent task, when the task is a subtask.
  public let parent: AppTaskSummary?
  /// Subtasks in sequence order, promoted and archived ones included.
  public let subtasks: [AppTaskSummary]
  /// Each current blocker with Core's ready rule applied; empty unless blocked.
  public let blockers: [AppBlocker]
}

/// One blocker of a blocked task.
public struct AppBlocker: Equatable, Sendable {
  /// Whether the blocker counts towards being ready to unblock.
  public enum State: String, Equatable, Sendable {
    /// A completed, unpromoted task.
    case done
    /// A party, a URL or a task not done; a promoted task stays open.
    case open
    /// A dropped task, which calls for a re-plan.
    case dropped
  }

  /// A bare task reference, an `ext:` party or a masked URL.
  public let ref: String
  /// The blocker task, nil for a party or a URL.
  public let task: AppTaskSummary?
  /// Core's ready state for this blocker.
  public let state: State
}

/// A related task's identity and state, for rows that name it.
public struct AppTaskSummary: Equatable, Sendable {
  /// Canonical task reference.
  public let ref: String
  /// Task title.
  public let title: String
  /// Stored task status.
  public let status: String
  /// Read-only external tracker reference, for a promoted task.
  public let externalRef: String?
}

extension AppTask {
  init(
    _ task: TaskDetails, submission: TaskEvent? = nil, resolved: [CommentDetails] = [],
    detail: AppTaskDetail? = nil
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
      detail: detail,
      comments: (task.comments ?? []).map(AppComment.init),
      resolvedComments: resolved.map(AppComment.init))
  }
}

extension AppTaskDetail {
  init(_ inspection: TaskInspection) {
    let task = inspection.task
    func summary(_ ref: String) -> AppTaskSummary? {
      inspection.related.first { $0.ref == ref }.map {
        AppTaskSummary(ref: $0.ref, title: $0.title, status: $0.status, externalRef: $0.externalRef)
      }
    }
    self.init(
      parent: task.parent.flatMap(summary),
      subtasks: inspection.related.filter { $0.parent == task.ref }.compactMap { summary($0.ref) },
      blockers: (task.waiting?.on ?? []).map { blocker in
        guard blocker.hasPrefix("task:") else {
          return AppBlocker(ref: blocker, task: nil, state: .open)
        }
        let ref = String(blocker.dropFirst("task:".count))
        let state: AppBlocker.State =
          inspection.dropped.contains(ref)
          ? .dropped : inspection.open.contains(ref) ? .open : .done
        return AppBlocker(ref: ref, task: summary(ref), state: state)
      })
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

extension AppTask {
  /// How long a claim lasts without a heartbeat, as Core enforces it.
  public static var claimDuration: TimeInterval { TaskService.claimDuration }

  /// When the claim stops protecting the task, by Core's rule; nil when unclaimed or the
  /// heartbeat is unreadable.
  public var claimExpiresAt: Date? {
    guard claimedBy != nil, let claimedAt else { return nil }
    return try? TaskService.claimExpiry(claimedAt)  // unreadable: Core says corrupt, shown stale
  }

  /// Seconds since the claim's last heartbeat; nil when unclaimed or unreadable.
  public func claimAge(at now: Date) -> TimeInterval? {
    claimExpiresAt.map { max(0, now.timeIntervalSince($0) + Self.claimDuration) }
  }

  /// The claim no longer protects the task, so another agent can start it without
  /// stealing. An unreadable heartbeat counts as expired, as Doctor treats it as stale.
  public func claimExpired(at now: Date) -> Bool {
    guard claimedBy != nil else { return false }
    return claimExpiresAt.map { now >= $0 } ?? true
  }
}
