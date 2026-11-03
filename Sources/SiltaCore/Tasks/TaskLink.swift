/// A task link rendered using the shared reference vocabulary.
package struct TaskLink: Encodable, Equatable, Sendable {
  /// Describes the relationship to the target.
  package let rel: String

  /// Identifies an internal or external target.
  package let target: String
}
