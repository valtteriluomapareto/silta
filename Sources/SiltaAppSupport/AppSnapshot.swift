/// Task-based views loaded together; the inbox is a separate core read.
public struct AppSnapshot: Equatable, Sendable {
  /// Board and per-app open counts.
  public let board: AppBoard
  /// Current human inbox and review attention.
  public let work: AppWork
}
