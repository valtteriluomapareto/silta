/// What the Mac inspector shows about one task, read in one transaction.
package struct TaskInspection: Sendable {
  /// The normal detail read.
  package let task: TaskDetails

  /// Posts of the resolved threads the normal read hides, roots before replies.
  package let resolved: [CommentDetails]

  /// The parent, subtasks and blocker tasks, in sequence order.
  package let related: [TaskRelative]

  /// Blockers keeping a blocked task from being ready: parties, URLs and tasks not done (a
  /// promoted one included), with tasks as bare refs. Empty unless the task is blocked.
  package let open: [String]

  /// Dropped blocker tasks, as bare refs. Empty unless the task is blocked.
  package let dropped: [String]
}

/// A task another task names, as its parent, subtask or blocker.
package struct TaskRelative: Sendable {
  /// The workspace-prefixed task reference.
  package let ref: String

  /// The task title after secret policy is applied.
  package let title: String

  /// The current status.
  package let status: String

  /// The parent task's reference, if any.
  package let parent: String?

  /// The external tracker reference, for a promoted task.
  package let externalRef: String?
}
