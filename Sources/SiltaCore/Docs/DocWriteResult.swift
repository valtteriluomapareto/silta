/// Body-free receipt for one accepted document revision.
package struct DocWriteResult: Encodable, Sendable {
  /// The immutable revision ref, masked if it contains detected secret content.
  package let ref: String
  /// Whether the document is archived after the operation.
  package let archived: Bool
  /// Whether the operation changed truth; every successful edit creates a revision.
  package let changed: Bool
  /// Public warnings, kept outside the JSON data payload.
  package let warnings: [OutputWarning]
  /// The workspace actually resolved for attribution, never serialized.
  package let workspace: String
  /// Whether a supplied agent approval was committed, never serialized.
  package let approvalUsed: Bool

  init(
    ref: String, warnings: [OutputWarning], workspace: String, approvalUsed: Bool,
    archived: Bool = false, changed: Bool = true
  ) {
    self.ref = ref
    self.warnings = warnings
    self.workspace = workspace
    self.approvalUsed = approvalUsed
    self.archived = archived
    self.changed = changed
  }

  private enum CodingKeys: String, CodingKey { case ref, archived, changed }
}
