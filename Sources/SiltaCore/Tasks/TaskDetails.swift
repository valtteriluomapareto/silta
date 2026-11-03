/// The persisted fields needed to inspect and work on a task.
package struct TaskDetails: Encodable, Sendable {
  let id: Int64

  let workspaceID: Int64

  let appID: Int64?

  let repoPath: String?

  /// The workspace-prefixed task reference.
  package let ref: String

  /// The task title after secret policy is applied.
  package let title: String

  /// The current status.
  package let status: String

  /// The markdown description.
  package let description: String

  /// The current markdown checklist.
  package let plan: String

  /// The last stored plan revision; ticking does not advance it.
  package let planRev: Int

  /// The recorded completion or drop result.
  package let result: String?

  /// The creating actor including its session.
  package let createdBy: String

  /// The current claimant including its session.
  package let claimedBy: String?

  /// The current claim heartbeat as an ISO instant.
  package let claimedAt: String?

  /// The app explicitly associated with the task.
  package let app: String?

  /// The branch recorded when work was started.
  package let branch: String?

  /// The worktree recorded when work was started.
  package let worktree: String?

  /// The commit recorded at completion.
  package let doneSHA: String?

  /// The branch recorded at completion.
  package let doneBranch: String?

  /// Whether the completed worktree had uncommitted changes.
  package let doneDirty: Bool?

  /// The task's typed links.
  package var links: [TaskLink] = []

  /// Events are included only when timeline was requested.
  package var timeline: [TaskEvent]?

  enum CodingKeys: String, CodingKey {
    case ref, title, status, description, plan, result, app, branch, worktree, links, timeline
    case planRev = "plan_rev"
    case createdBy = "created_by"
    case claimedBy = "claimed_by"
    case claimedAt = "claimed_at"
    case doneSHA = "done_sha"
    case doneBranch = "done_branch"
    case doneDirty = "done_dirty"
  }
}
