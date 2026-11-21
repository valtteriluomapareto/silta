/// What the New Task sheet sends: a human's task goes straight to todo (D38).
public struct AppNewTask: Equatable, Sendable {
  /// The required title.
  public var title: String
  /// Optional Markdown description.
  public var description = ""
  /// Optional Markdown acceptance criteria.
  public var acceptance = ""
  /// An app slug; nil inherits the parent's app, or none.
  public var app: String?
  /// A parent task reference, for a subtask.
  public var parent: String?
  /// Backlog priority, from one (first) to three.
  public var priority = 2

  /// Starts a task with its title.
  public init(title: String) {
    self.title = title
  }
}
