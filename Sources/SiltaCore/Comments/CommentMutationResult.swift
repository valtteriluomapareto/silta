/// A discussion mutation receipt; only explanation posts create new refs.
package struct CommentMutationResult: Encodable, Sendable {
  /// The resulting state: resolved, reopened or deleted.
  package let action: String
  /// Canonical affected refs in first-appearance order.
  package let refs: [String]
  /// New explanation refs, retained by quiet output.
  package var created: [String] = []
  /// Refs already in the requested state; presentation metadata, outside JSON.
  package var unchanged: [String] = []
  /// Secret-policy diagnostics, outside the JSON data.
  package var warnings: [OutputWarning] = []
  /// True only if this mutation recorded consent.
  package var approvalUsed = false

  enum CodingKeys: String, CodingKey { case action, refs, created }
}
