/// A task pointer with the current ask or external tracker, as applicable.
package struct InboxTask: Encodable, Sendable {
  /// Canonical task reference in the selected workspace.
  package let ref: String
  /// Task title.
  package let title: String
  /// Latest block reason, with secrets masked.
  package let why: String?
  /// Current blockers, with sensitive URL content masked.
  package let on: [String]?
  /// Task's UTC follow-up day.
  package let followUpAt: String?
  /// External tracker reference, whose status is not refreshed locally.
  package let externalRef: String?

  init(_ task: TaskDetails) {
    ref = task.ref
    title = task.title
    why = task.waiting?.why
    on = task.waiting?.on
    followUpAt = task.followUpAt
    externalRef = task.externalRef
  }

  enum CodingKeys: String, CodingKey {
    case ref, title, why, on
    case followUpAt = "follow_up_at"
    case externalRef = "external_ref"
  }
}
