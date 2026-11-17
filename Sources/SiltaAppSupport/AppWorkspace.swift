/// A workspace available to the viewer.
public struct AppWorkspace: Equatable, Sendable {
  /// Workspace selector used by commands.
  public let slug: String
  /// Human-readable workspace name.
  public let name: String
}
