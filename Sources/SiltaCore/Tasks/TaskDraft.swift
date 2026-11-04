/// Values supplied when creating a task; no writes happen during construction.
package struct TaskDraft: Sendable {
  /// The `--app` word that chooses non-code work instead of an app.
  package static let noneApp = "none"

  /// The required task title.
  package var title: String

  /// Backlog priority, from one (first) to three.
  package var priority = 2

  /// The optional markdown description.
  package var description = ""

  /// Claims the newly authorized work immediately.
  package var start = false

  /// Names a parent task in the selected workspace.
  package var parent: String?

  /// Names an explicit app, or `none` for non-code work; absent takes the parent's app.
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

  /// The creation options without a title, body or input file contents.
  package var command: String {
    var value = "silta task add"
    if priority != 2 { value += " --priority \(priority)" }
    if start { value += " --start" }
    if let parent { value += " --parent " + shellWord(parent) }
    if let app { value += " --app " + shellWord(app) }
    for topic in topics { value += " --topic " + shellWord(topic) }
    if let source { value += " --from " + shellWord(source) }
    return value
  }

}
