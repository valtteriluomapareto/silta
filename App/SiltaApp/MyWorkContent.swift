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
  let other: [AppAttention]
  let remaining: Int
  var hasMatches: Bool {
    !questions.isEmpty || !answers.isEmpty || !reviews.isEmpty || !documents.isEmpty
      || !tasks.isEmpty || !other.isEmpty
  }

  init(snapshot: AppSnapshot, search: String, now: Date) {
    let board = snapshot.board
    let byRef = Dictionary(
      uniqueKeysWithValues: (board.todo + board.doing + board.review + board.doneThisWeek
        + board.proposals).map { ($0.ref, $0) })
    let items = snapshot.work.items
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
    other = items.filter {
      !["question", "answer", "doc_proposal", "proposal"].contains($0.kind) && matches($0)
    }
    remaining = snapshot.work.remaining
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
