/// A discussion post; deleted bodies are replaced by a placeholder on reads.
package struct CommentDetails: Encodable, Sendable {
  let id: Int64
  /// The canonical task/comment reference.
  package let ref: String
  /// Stored kinds remain readable even when a newer writer introduced them.
  package let kind: String
  /// Markdown after the posting secret policy, or [deleted].
  package let body: String
  /// The posting actor, including its session.
  package let actor: String
  /// The root comment reference for a reply.
  package let replyTo: String?
  /// Whether the author soft-deleted this post.
  package let deleted: Bool
  /// Resolution of the containing thread, when resolved.
  package let resolvedAt: String?
  /// The actor who resolved the containing thread, when known.
  package let resolvedBy: String?
  /// Sorted complete recipients, including explicit targets and body mentions.
  package let mentions: [String]
  /// Whether the asker or current claimer selected this answer.
  package let accepted: Bool
  /// Whether a live question has a live answer from an addressee or human.
  package var answered: Bool?
  /// An optional note citation.
  package let source: String?
  /// The posting instant.
  package let createdAt: String

  enum CodingKeys: String, CodingKey {
    case ref, kind, body, actor, deleted, mentions, accepted, answered
    case source = "from"
    case replyTo = "reply_to"
    case resolvedAt = "resolved_at"
    case resolvedBy = "resolved_by"
    case createdAt = "created_at"
  }

  func isAnswered(by posts: [CommentDetails]) -> Bool {
    !deleted
      && posts.contains {
        $0.replyTo == ref && $0.kind == "answer" && !$0.deleted
          && (ActorID.parse($0.actor)?.isHuman == true || mentions.contains($0.actor))
      }
  }
}
