/// Body-free receipt for one accepted document revision.
package struct DocWriteResult: Encodable, Sendable {
  /// The immutable revision ref, masked if it contains detected secret content.
  package let ref: String
  /// An accepted edit is active.
  package let archived = false
  /// Every successful save creates a revision, including identical content.
  package let changed = true
  /// Public warnings, kept outside the JSON data payload.
  package let warnings: [OutputWarning]
  /// The workspace actually resolved for attribution, never serialized.
  package let workspace: String
  /// Whether a supplied agent approval was committed, never serialized.
  package let approvalUsed: Bool

  private enum CodingKeys: String, CodingKey { case ref, archived, changed }
}
