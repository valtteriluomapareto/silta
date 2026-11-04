/// A committed post with warnings and consent-use metadata outside its JSON value.
package struct CommentResult: Sendable {
  /// The created discussion post.
  package let comment: CommentDetails
  /// Secret handling or an unclaimed handoff warning.
  package let warnings: [OutputWarning]
  /// Whether this post recorded human consent.
  package let approvalUsed: Bool
}
