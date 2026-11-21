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
  /// The blocked tasks of a `due`, `ready` or `replan` entry, as Core lists them.
  public internal(set) var blocked: [AppBlockedTask] = []
}

/// A blocked task in a follow-up entry.
public struct AppBlockedTask: Equatable, Sendable {
  /// Canonical task reference.
  public let ref: String
  /// Task title.
  public let title: String
  /// The latest block reason, masked.
  public let why: String?
  /// Current blockers, masked.
  public let on: [String]
  /// The stored UTC follow-up day.
  public let followUpAt: String?
  /// Blockers keeping it from being ready, by Core's rule: parties, URLs and tasks not
  /// done, tasks as bare refs.
  public internal(set) var open: [String] = []
  /// Dropped blocker tasks, as bare refs.
  public internal(set) var dropped: [String] = []
}

extension AppAttention {
  /// The entry with each blocked task's open and dropped blockers filled in.
  func withUnmet(_ unmet: [String: (open: [String], dropped: [String])]) -> AppAttention {
    var copy = self
    copy.blocked = blocked.map { task in
      var task = task
      task.open = unmet[task.ref]?.open ?? []
      task.dropped = unmet[task.ref]?.dropped ?? []
      return task
    }
    return copy
  }

  init(_ item: InboxItem) {
    self.init(
      kind: item.kind, target: item.target, ref: item.ref,
      refs: item.docProposal?.documentReferences ?? item.tasks?.map(\.ref) ?? item.task.map { [$0] }
        ?? item.ref.map { [$0] } ?? [],
      task: item.task, title: item.docProposal?.displayTitle ?? item.tasks?.first?.title,
      author: item.author ?? item.docProposal?.author,
      body: item.body ?? item.tasks?.first?.why, createdAt: item.createdAt,
      documentRevision: item.docProposal?.revision, sourceTask: item.docProposal?.sourceTask,
      commands: item.next,
      blocked: ["due", "ready", "replan"].contains(item.kind)
        ? (item.tasks ?? []).map {
          AppBlockedTask(
            ref: $0.ref, title: $0.title, why: $0.why, on: $0.on ?? [], followUpAt: $0.followUpAt)
        } : [])
  }
}
