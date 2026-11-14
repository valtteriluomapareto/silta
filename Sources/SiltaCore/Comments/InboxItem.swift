/// One actionable attention item; `next` commands are usable by the caller.
package struct InboxItem: Encodable, Sendable {
  /// Attention category for ordering and rendering.
  package let kind: String
  /// Canonical post or proposal/tracker task reference.
  package var ref: String?
  /// Canonical containing task reference.
  package var task: String?
  /// Complete creating or posting actor.
  package var author: String?
  /// Live Markdown body, quoted when rendered as text.
  package var body: String?
  /// Creation time; each category defines its ordering.
  package var createdAt: String?
  /// Safe commands or an explicit ask-human confirmation instruction.
  package let next: [String]

  /// Original post kind, independent of the attention category.
  package var postKind: String?
  /// Question reference for an answer.
  package var replyTo: String?
  /// Authors of existing outsider answers awaiting confirmation on a question.
  package var relayedBy: [String]?

  /// Tasks and asks in a grouped item, or the single proposal/tracker pointer.
  package var tasks: [InboxTask]?
  /// Bounded document evidence, distinct from task proposal pointers.
  package var docProposal: DocProposalPreviewGroup?
  var proposalGroup: DocProposalGroup?
  /// External party or URL for a due group, redacted for display.
  package var target: String?
  /// Earliest follow-up day in a due group or fallback.
  package var followUpAt: String?

  enum CodingKeys: String, CodingKey {
    case kind, ref, task, author, body, next, tasks, target
    case docProposal = "doc_proposal"
    case followUpAt = "follow_up_at"
    case createdAt = "created_at"
    case postKind = "post_kind"
    case replyTo = "reply_to"
    case relayedBy = "relayed_by"
  }
}
