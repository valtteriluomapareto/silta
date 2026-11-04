/// Input for an append-only task discussion post.
package struct CommentDraft: Sendable {
  /// The Markdown content, at most 8000 Unicode scalars.
  package var body: String
  /// One of comment, decision or handoff.
  package var kind: String
  /// Retains secrets with recorded human consent.
  package var allowSecret = false

  /// Creates an ordinary discussion post unless a kind is supplied.
  package init(body: String, kind: String = "comment") {
    self.body = body
    self.kind = kind
  }
}
