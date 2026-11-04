import Foundation

/// A prepared creation; identifiers and git observations survive transaction retries.
struct TaskCreation: Sendable {
  var draft: TaskDraft

  var uid: String

  var at: Date

  var path: String?

  /// The app the task takes, explicit or inherited from its parent.
  var app: String?

  var git = TaskGit()

  var redacted = false
}
