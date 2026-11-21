import Foundation
import SiltaAppSupport

nonisolated struct MyWorkContent {
  struct Question: Identifiable {
    let item: AppAttention
    let metadata: String
    var id: String { item.stableID }
    var ref: String? { item.task ?? item.ref }
    var headline: String { item.body ?? item.title ?? "Question" }

    func command(reader: AppReader, workspace: String) -> AppCommand? {
      reader.commands(for: item, workspace: workspace).first { $0.title == "Answer question" }
    }
  }

  /// An answer to the human's own question, which they may accept.
  struct Answer: Identifiable {
    let item: AppAttention
    let metadata: String
    var id: String { item.stableID }

    /// Core offers accepting only to the asker or the current claimer.
    func canAccept(reader: AppReader, workspace: String) -> Bool {
      reader.commands(for: item, workspace: workspace).contains { $0.title == "Accept answer" }
    }
  }

  struct Review: Identifiable {
    let task: AppTask
    let metadata: String
    var id: String { task.ref }
  }

  struct Proposal: Identifiable {
    let item: AppAttention
    let title: String
    let metadata: String
    let ref: String
    var id: String { item.stableID }
  }

  let questions: [Question]
  let answers: [Answer]
  let reviews: [Review]
  let documents: [Proposal]
  let tasks: [Proposal]
  let followUps: [FollowUp]
  let other: [AppAttention]
  let remaining: Int
  var hasMatches: Bool {
    !questions.isEmpty || !answers.isEmpty || !reviews.isEmpty || !documents.isEmpty
      || !tasks.isEmpty || !followUps.isEmpty || !other.isEmpty
  }

  /// `all` replaces the capped inbox items when My work shows every waiting item.
  init(snapshot: AppSnapshot, all: [AppAttention]? = nil, search: String, now: Date) {
    let board = snapshot.board
    let byRef = Dictionary(
      uniqueKeysWithValues: (board.todo + board.doing + board.review + board.doneThisWeek
        + board.proposals).map { ($0.ref, $0) })
    let items = all ?? snapshot.work.items
    func matches(_ item: AppAttention, extra: [String] = []) -> Bool {
      AppSearch.matches(
        search,
        values: [
          item.kind, item.ref ?? "", item.task ?? "", item.title ?? "", item.body ?? "",
          item.author ?? "", item.sourceTask ?? "",
        ] + item.refs + extra)
    }
    questions = items.filter {
      $0.kind == "question" && matches($0, extra: [byRef[$0.task ?? ""]?.title ?? ""])
    }.map { Self.question($0, task: byRef[$0.task ?? ""], now: now) }
    answers = items.filter {
      $0.kind == "answer" && matches($0, extra: [byRef[$0.task ?? ""]?.title ?? ""])
    }.map { Self.answer($0, task: byRef[$0.task ?? ""], now: now) }
    reviews = snapshot.work.reviews.map { Self.review($0, now: now) }.filter {
      AppSearch.matches(
        search, values: [$0.task.ref, $0.task.title, $0.task.description, $0.metadata])
    }
    documents = items.filter { $0.kind == "doc_proposal" && matches($0) }.map(Self.document)
    tasks = items.filter {
      $0.kind == "proposal" && matches($0, extra: [byRef[$0.ref ?? ""]?.app ?? ""])
    }.map { Self.proposal($0, task: byRef[$0.refs.first ?? $0.ref ?? ""]) }
    followUps = items.filter { ["due", "replan"].contains($0.kind) }.flatMap { item in
      item.blocked.filter { matches(item, extra: [$0.ref, $0.title, $0.why ?? ""] + $0.on) }
        .map { FollowUp(item: item, task: $0, board: byRef[$0.ref], now: now) }
    }
    other = items.filter {
      !["question", "answer", "doc_proposal", "proposal", "due", "replan"].contains($0.kind)
        && matches($0)
    }
    remaining = all == nil ? snapshot.work.remaining : 0
  }

  /// The line under My work's items, beside its Show all or Show fewer button.
  static func footer(remaining: Int, showingAll: Bool, loaded: Bool = true) -> String {
    if showingAll, !loaded { return "Reading every waiting item…" }
    if showingAll { return "Showing everything waiting, including proposals older than 14 days." }
    guard remaining > 0 else { return "Proposals older than 14 days are hidden." }
    return "\(remaining) more waiting \(remaining == 1 ? "item" : "items"), plus any proposals "
      + "older than 14 days."
  }

  private static func question(_ item: AppAttention, task: AppTask?, now: Date) -> Question {
    let actor = item.author.map { ActorPresentation($0).name } ?? "Someone"
    let title = task?.title ?? item.task
    let metadata =
      ([actor + " asks you"]
      + [title, RelativeAge.text(item.createdAt, now: now)].compactMap { $0 })
      .joined(separator: " · ")
    return Question(item: item, metadata: metadata)
  }

  /// The task a My work item may unblock: only a `ready` one, whose blockers are done.
  /// Core unblocks a human's task even with open blockers, so `replan` keeps its command.
  static func unblockRef(_ item: AppAttention) -> String? {
    item.kind == "ready" && item.refs.count == 1 ? item.refs.first : nil
  }

  private static func answer(_ item: AppAttention, task: AppTask?, now: Date) -> Answer {
    let actor = item.author.map { ActorPresentation($0).name } ?? "Someone"
    let metadata =
      ([actor + " answered you"]
      + [task?.title ?? item.task, RelativeAge.text(item.createdAt, now: now)].compactMap { $0 })
      .joined(separator: " · ")
    return Answer(item: item, metadata: metadata)
  }

  private static func review(_ task: AppTask, now: Date) -> Review {
    var metadata = ["Waiting for your review"]
    if let submission = task.submission {
      let elapsed = RelativeAge.text(submission.at, now: now).map { " " + $0 } ?? ""
      metadata.append(ActorPresentation(submission.actor).name + " submitted it" + elapsed)
    }
    if !task.steps.isEmpty {
      metadata.append("step \(task.steps.filter(\.done).count) of \(task.steps.count)")
    }
    return Review(task: task, metadata: metadata.joined(separator: " · "))
  }

  private static func document(_ item: AppAttention) -> Proposal {
    var metadata: [String] = []
    if let revision = item.documentRevision {
      metadata.append((revision == 1 ? "new doc @" : "revision @") + String(revision))
    }
    if let author = item.author { metadata.append("by " + ActorPresentation(author).name) }
    let line = metadata.joined(separator: " ") + (item.sourceTask.map { " · from " + $0 } ?? "")
    return Proposal(
      item: item, title: item.title ?? "Document proposal", metadata: line,
      ref: item.refs.first ?? item.ref ?? "")
  }

  private static func proposal(_ item: AppAttention, task: AppTask?) -> Proposal {
    let author = item.author.map { "by " + ActorPresentation($0).name }
    return Proposal(
      item: item, title: item.title ?? task?.title ?? "Task proposal",
      metadata: [task?.app, author].compactMap { $0 }.joined(separator: " · "),
      ref: item.refs.first ?? item.ref ?? "")
  }
}

/// A blocked task whose follow-up day came, or whose blocker was dropped.
nonisolated struct FollowUp: Identifiable, Equatable {
  let item: AppAttention
  let task: AppBlockedTask
  /// The board's row for the task, which carries Core's waiting state.
  let board: AppTask?
  let now: Date

  var id: String { item.kind + ":" + task.ref }
  var replan: Bool { item.kind == "replan" }

  var title: String { (replan ? "Re-plan: " : "Follow up: ") + task.title }

  var subtitle: String {
    let waiting = board?.waiting
    let age = waiting.map { $0.ageDays == 1 ? "blocked 1 day" : "blocked \($0.ageDays) days" }
    let lead =
      replan
      ? "A blocker was dropped: " + dropped.joined(separator: ", ")
      : "Follow-up was due " + (task.followUpAt ?? "")
    return ([lead] + [age].compactMap { $0 }).joined(separator: " · ")
  }

  /// Dropped blocker tasks, as bare refs.
  var dropped: [String] { (board?.waiting?.dropped ?? []).map(Self.bare) }

  /// The blockers Unblock anyway unlinks: every current blocker but dropped tasks.
  var openBlockers: [String] {
    let dropped = Set(dropped)
    return task.on.map(Self.bare).filter { !dropped.contains($0) }
  }

  private static func bare(_ blocker: String) -> String {
    blocker.hasPrefix("task:") ? String(blocker.dropFirst("task:".count)) : blocker
  }

  /// The confirm step's sentence before Unblock anyway.
  var unblockWarning: String {
    let open = openBlockers
    return open.isEmpty
      ? "Unblocking returns it to Todo."
      : "Unblocking returns it to Todo and unlinks its open "
        + (open.count == 1 ? "blocker " : "blockers ") + open.joined(separator: ", ") + "."
  }
}
