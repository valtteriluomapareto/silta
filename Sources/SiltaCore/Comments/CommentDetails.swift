/// A discussion post; deleted bodies are replaced by a placeholder on reads.
package struct CommentDetails: Encodable, Sendable {
  /// The canonical task/comment reference.
  package let ref: String
  /// Stored kinds remain readable even when a newer writer introduced them.
  package let kind: String
  /// Markdown after the posting secret policy, or [deleted].
  package let body: String
  /// The posting actor, including its session.
  package let actor: String
  /// Validated recipient actors, including resolved @me.
  package let mentions: [String]
  /// The root comment reference for a reply.
  package let replyTo: String?
  /// A note citation, when set.
  package let source: String?
  /// Whether the asker accepted this answer.
  package let accepted: Bool
  /// Whether the author soft-deleted this post.
  package let deleted: Bool
  /// Resolution of the containing thread, when resolved.
  package let resolvedAt: String?
  /// The actor who resolved the containing thread.
  package let resolvedBy: String?
  /// The posting instant.
  package let createdAt: String

  enum CodingKeys: String, CodingKey {
    case ref, kind, body, actor, mentions, source, accepted, deleted
    case replyTo = "reply_to"
    case resolvedAt = "resolved_at"
    case resolvedBy = "resolved_by"
    case createdAt = "created_at"
  }
}
