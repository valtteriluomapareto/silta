/// A bounded, masked rendering of one stored document revision.
package struct DocReadResult: Encodable, Sendable {
  /// The selected doc or immutable revision reference.
  package let ref: String
  /// Rendered metadata and content, with complete continuations when clipped.
  package let output: String
}

struct DocReadSelection {
  let revision: DocRevision?
  let archived: Bool
  let pending: [Int]
  let pendingCount: Int
}
