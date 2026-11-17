import SiltaCore

/// One core inbox action; separate questions on one task stay separate entries.
public struct AppAttention: Equatable, Sendable {
  /// Stable presentation identity, independent of row position.
  public var stableID: String {
    kind + ":" + (target ?? "") + ":" + (ref ?? task ?? refs.joined(separator: ","))
  }
  /// Core inbox category.
  public let kind: String
  /// External grouping target, already redacted by Core.
  public let target: String?
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
  /// Immutable revision of the newest document proposal, if applicable.
  public let documentRevision: Int?
  /// Recorded source task for that document proposal, if known.
  public let sourceTask: String?
  /// Human-form core next commands; copy templates are a separate presentation concern.
  public let commands: [String]
}

extension AppAttention {
  init(_ item: InboxItem) {
    self.init(
      kind: item.kind, target: item.target, ref: item.ref,
      refs: item.docProposal?.documentReferences ?? item.tasks?.map(\.ref) ?? item.task.map { [$0] }
        ?? item.ref.map { [$0] } ?? [],
      task: item.task, title: item.docProposal?.displayTitle ?? item.tasks?.first?.title,
      author: item.author ?? item.docProposal?.author,
      body: item.body ?? item.tasks?.first?.why, createdAt: item.createdAt,
      documentRevision: item.docProposal?.revision, sourceTask: item.docProposal?.sourceTask,
      commands: item.next)
  }
}
