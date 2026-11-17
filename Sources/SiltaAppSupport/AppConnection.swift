/// Workspace map values for the viewer.
public struct AppConnection: Equatable, Sendable {
  /// Canonical typed edge reference.
  public let attachment: String
  /// Source app slug.
  public let source: String
  /// Target app slug or service-prefixed slug.
  public let target: String
  /// Connection kind.
  public let kind: String
  /// Connection purpose.
  public let summary: String
  /// Configured app-relative code references.
  public let codeReferences: [String]
}
