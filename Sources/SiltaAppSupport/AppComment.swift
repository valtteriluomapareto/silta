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
}
