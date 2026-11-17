/// Workspace map values for the viewer.
public struct AppWorkspaceMap: Equatable, Sendable {
  /// Apps in slug order.
  public let apps: [AppMapApp]
  /// External services in slug order.
  public let services: [AppMapService]
  /// Connections in source, target and kind order.
  public let connections: [AppConnection]
}
