/// An attributed event from the task's history.
package struct TaskEvent: Encodable, Sendable {
  /// Identifies the kind of change.
  package let kind: String

  /// Records the exact actor who made the change.
  package let actor: String

  /// Holds the event's retained, secret-checked body.
  package let body: String?

  /// Records when the change occurred.
  package let at: String
}
