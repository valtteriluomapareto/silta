/// A live discussion entry projected by the core's normal task read.
public struct AppComment: Equatable, Sendable {
  /// Canonical comment reference.
  public let ref: String
  /// Stored discussion kind.
  public let kind: String
  /// Full actor identity.
  public let actor: String
  /// Markdown body, including the core's deleted-content placeholder.
  public let body: String
  /// UTC creation timestamp.
  public let createdAt: String
  /// Root reference for a reply.
  public let replyTo: String?
  /// Whether the asker or claimer accepted this answer.
  public let accepted: Bool
  /// Whether the author deleted this post; its body is Core's placeholder.
  public let deleted: Bool
  /// When the thread was resolved; set on the root only.
  public let resolvedAt: String?
  /// Who resolved the thread; set on the root only.
  public let resolvedBy: String?
  /// Complete recipients, such as the actors a question is addressed to.
  public let mentions: [String]

  init(
    ref: String, kind: String, actor: String, body: String, createdAt: String,
    replyTo: String?, accepted: Bool = false, deleted: Bool = false, resolvedAt: String? = nil,
    resolvedBy: String? = nil, mentions: [String] = []
  ) {
    self.ref = ref
    self.kind = kind
    self.actor = actor
    self.body = body
    self.createdAt = createdAt
    self.replyTo = replyTo
    self.accepted = accepted
    self.deleted = deleted
    self.resolvedAt = resolvedAt
    self.resolvedBy = resolvedBy
    self.mentions = mentions
  }
}
