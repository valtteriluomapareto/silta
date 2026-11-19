/// Workspace map values for the viewer.
public struct AppMapService: Equatable, Sendable {
  /// Service slug.
  public let slug: String
  /// Display name.
  public let name: String
  /// Service purpose.
  public let summary: String?
  /// Canonical typed map reference.
  public let attachment: String

  /// The key connections use for this service: `service:` and the raw slug. Unlike
  /// `attachment`, it is not percent-encoded.
  public var key: String { "service:" + slug }
}
