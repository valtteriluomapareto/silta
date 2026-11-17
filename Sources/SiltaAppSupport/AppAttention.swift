import SiltaCore

/// One core inbox action; separate questions on one task stay separate entries.
public struct AppAttention: Equatable, Sendable {
  /// Core inbox category.
  public let kind: String
  /// Canonical item reference, when present.
  public let ref: String?
  /// Display refs for a grouped action, or its containing task/item.
  public let refs: [String]
  /// Containing task reference, when present.
  public let task: String?
  /// Proposal task title, when present.
  public let title: String?
  /// Creating or posting actor.
  public let author: String?
  /// Full attention body, when present.
  public let body: String?
  /// UTC creation timestamp.
  public let createdAt: String?
  /// Human-form core next commands; copy templates are a separate presentation concern.
  public let commands: [String]
}

extension AppAttention {
  init(_ item: InboxItem) {
    self.init(
      kind: item.kind, ref: item.ref,
      refs: item.tasks?.map(\.ref) ?? item.task.map { [$0] } ?? item.ref.map { [$0] } ?? [],
      task: item.task, title: item.tasks?.first?.title, author: item.author,
      body: item.body ?? item.tasks?.first?.why, createdAt: item.createdAt, commands: item.next)
  }
}
