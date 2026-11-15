/// A body-free receipt for a stored pending revision.
package struct DocProposalResult: Encodable, Sendable {
  /// The immutable pending revision reference.
  package let ref: String
  /// Warnings for the command envelope.
  package let warnings: [OutputWarning]
  /// The resolved workspace for command reporting.
  package let workspace: String

  private enum CodingKeys: String, CodingKey { case ref }
}
