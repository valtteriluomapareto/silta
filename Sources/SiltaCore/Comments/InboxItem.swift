/// One actionable discussion post; `next` commands are usable by the caller.
package struct InboxItem: Encodable, Sendable {
  /// Attention category: question, answer or discussion.
  package let kind: String
  /// Canonical post reference.
  package let ref: String
  /// Canonical containing task reference.
  package let task: String
  /// Complete posting actor.
  package let author: String
  /// Live Markdown body, quoted when rendered as text.
  package let body: String
  /// Posting time used for oldest-first ordering within each category.
  package let createdAt: String
  /// Safe commands or an explicit ask-human confirmation instruction.
  package let next: [String]

  /// Original post kind, independent of the attention category.
  package let postKind: String
  /// Question reference for an answer.
  package let replyTo: String?
  /// Authors of existing outsider answers awaiting confirmation on a question.
  package let relayedBy: [String]?

  enum CodingKeys: String, CodingKey {
    case kind, ref, task, author, body, next
    case createdAt = "created_at"
    case postKind = "post_kind"
    case replyTo = "reply_to"
    case relayedBy = "relayed_by"
  }
}
