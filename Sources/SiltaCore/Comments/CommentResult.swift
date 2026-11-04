/// A committed post with warnings and consent-use metadata outside its JSON value.
package struct CommentResult: Encodable, Sendable {
  /// The created discussion post.
  package let comment: CommentDetails
  /// Secret handling or an unclaimed handoff warning.
  package let warnings: [OutputWarning]
  /// Whether this post recorded human consent.
  package let approvalUsed: Bool
  /// Whether this transaction released the posting actor's claim.
  package let released: Bool

  private enum CodingKeys: String, CodingKey { case released }

  /// Keeps the existing post fields flat and excludes warning/consent metadata.
  package func encode(to encoder: any Encoder) throws {
    try comment.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(released, forKey: .released)
  }
}
