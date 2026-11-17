/// A labeled shell command the viewer copies for the human to run.
public struct AppCommand: Equatable, Sendable {
  /// Human-readable action label.
  public let title: String
  /// Literal shell text scoped to the selected data home.
  public let text: String
}
