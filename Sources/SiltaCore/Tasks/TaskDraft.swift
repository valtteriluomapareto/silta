/// Values supplied when creating a task; no writes happen during construction.
package struct TaskDraft: Sendable {
  /// The required task title.
  package var title: String

  /// The optional markdown description.
  package var description = ""

  /// Claims the newly authorized work immediately.
  package var start = false

  /// Names a parent task in the selected workspace.
  package var parent: String?

  /// Names an explicit app; absent means non-code work.
  package var app: String?

  /// Names existing workspace topics.
  package var topics: [String] = []

  /// Names an originating note reference.
  package var source: String?

  /// Allows a human to retain detected secret content.
  package var allowSecret = false

  /// Starts a draft with its required title.
  package init(title: String) {
    self.title = title
  }
}
