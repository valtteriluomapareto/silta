/// Input for an append-only task discussion post.
package struct CommentDraft: Sendable {
  /// The Markdown content, at most 8000 Unicode scalars.
  package var body: String
  /// One of comment, question, answer, decision or handoff.
  package var kind: String
  /// A comment in the same task; replies normalize to its root.
  package var replyTo: String?
  /// Complete actors or me; combined with body mentions.
  package var to: [String] = []
  /// An optional note: citation.
  package var source: String?
  /// Retains secrets with recorded human consent.
  package var allowSecret = false

  /// Creates an ordinary discussion post unless a kind is supplied.
  package init(body: String, kind: String = "comment") {
    self.body = body
    self.kind = kind
  }
}
