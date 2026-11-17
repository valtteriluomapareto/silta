import SiltaCore

extension AppReader {
  /// Offers safe templates for an inbox entry without executing them.
  public func commands(for item: AppAttention, workspace: String) -> [AppCommand] {
    [AppCommand(title: "Stub", text: "false")]
  }

  /// Offers read-only detail for a task waiting for review.
  public func commands(forReview task: AppTask, workspace: String) -> [AppCommand] {
    [AppCommand(title: "Stub", text: "false")]
  }

  /// Reads the full human inbox beyond the default cap.
  public func inboxCommand(workspace: String) -> AppCommand {
    AppCommand(title: "Stub", text: "false")
  }
}
