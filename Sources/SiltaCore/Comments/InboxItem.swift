/// One actionable discussion post; `next` commands are usable by the caller.
package struct InboxItem: Encodable, Sendable {
  /// Attention category: question, answer or comment.
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
  /// Available actions; answering and explicit resolution are alternatives.
  package let next: [String]

  var rank: Int { kind == "question" ? 0 : kind == "answer" ? 1 : 2 }

  enum CodingKeys: String, CodingKey {
    case kind, ref, task, author, body, next
    case createdAt = "created_at"
  }
}
