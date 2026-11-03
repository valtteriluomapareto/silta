import Foundation

/// A prepared creation; identifiers and git observations survive transaction retries.
struct TaskCreation: Sendable {
  var draft: TaskDraft

  var uid: String

  var at: Date

  var path: String?

  var git = TaskGit()

  var redacted = false
}
