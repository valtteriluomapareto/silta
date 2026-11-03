/// Filters task reads without changing stored task state.
package struct TaskFilter: Sendable {
  /// Restricts the status vocabulary.
  package var status: String?

  /// Restricts the app slug.
  package var app: String?

  /// Restricts the topic slug.
  package var topic: String?

  /// Shows only tasks created or claimed by this exact actor.
  package var mine = false

  /// Includes proposals from other actors.
  package var proposed = false

  /// Includes tasks whose computed archive state is archived.
  package var archived = false

  /// Starts with the caller's visible open backlog.
  package init() {}
}
