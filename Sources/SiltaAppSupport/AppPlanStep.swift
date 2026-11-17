/// One top-level checklist entry, excluding fenced examples and nested items.
public struct AppPlanStep: Equatable, Sendable {
  /// Markdown label after the checkbox.
  public let title: String
  /// Whether the checkbox is checked.
  public let done: Bool
}
