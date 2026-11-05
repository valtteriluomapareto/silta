/// Input for an append-only task discussion post.
package struct CommentDraft: Sendable {
  /// The Markdown content, at most 8000 Unicode scalars.
  package var body: String
  /// One of comment, question, answer, decision or handoff.
  package var kind: String
  let explicitKind: Bool
  /// A post whose thread this reply joins.
  package var replyTo: String?
  /// Explicit complete actors or `me`; stored together with body mentions.
  package var recipients: [String] = []
  /// An optional note citation.
  package var source: String?
  /// Retains secrets with recorded human consent.
  package var allowSecret = false

  /// Creates an ordinary discussion post unless a kind is supplied.
  package init(body: String, kind: String? = nil) {
    self.body = body
    self.kind = kind ?? "comment"
    self.explicitKind = kind != nil
  }
}
