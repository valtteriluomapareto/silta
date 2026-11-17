/// Workspace map values for the viewer.
public struct AppMapApp: Equatable, Sendable {
  /// App slug.
  public let slug: String
  /// Display name.
  public let name: String
  /// Repository slug.
  public let repo: String
  /// Configured development ref.
  public let ref: String
  /// Optional production ref.
  public let productionRef: String?
  /// Optional repository subdirectory.
  public let subpath: String?
  /// App purpose.
  public let summary: String?
  /// Stored lifecycle.
  public let lifecycle: String
  /// Canonical typed map reference.
  public let attachment: String
}
