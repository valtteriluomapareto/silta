import Foundation
import GRDB

/// The current task's handoff and question state, and the caller's own inbox attention,
/// read inside the brief's snapshot. Items render from kind, refs, author, body and
/// `next` alone, so new inbox categories keep the same section shape.
struct BriefDiscussion {
  /// Items shown in each of the task and inbox sections.
  static let items = 3
  /// Characters of each item's body excerpt, after masking.
  static let excerpt = 200

  let db: Database
  let service: TaskService
  let caller: ActorID
  let workspace: String
  let command: String
  let current: TaskDetails?
  /// Character budget of the whole brief; the handoff takes a share of it.
  let characters: Int

  /// Sections for the current task and sections after it; the inbox is empty exactly
  /// when the caller has no attention.
  func sections() throws -> (task: [BriefSection], inbox: [BriefSection]) {
    let inbox = try service.inbox(for: caller, workspace: workspace, all: true, in: db)
    var emitted: Set<String> = []
    var task: [BriefSection] = []
    if let current {
      let posts = try TaskService.discussion(current, timeline: true, in: db)
      if let handoff = TaskService.newestHandoff(posts) { task.append(section(handoff)) }
      task += inbox.items.filter { onTask($0) }.prefix(Self.items).map {
        BriefSection(id: "task_inbox", text: render($0, emitted: &emitted))
      }
      let open = posts.filter {
        $0.kind == "question" && $0.replyTo == nil && !$0.deleted && $0.resolvedAt == nil
      }
      if !open.isEmpty {
        let answered = open.filter { $0.answered == true }.count
        task.append(
          BriefSection(
            id: "questions",
            text: "questions: \(open.count) open"
              + (answered == 0 ? "" : " (\(answered) answered)") + "\n"))
      }
    }
    guard !inbox.items.isEmpty else { return (task, []) }
    let count = inbox.items.count
    let above = inbox.items.filter { onTask($0) }.count
    var sections = [
      BriefSection(
        id: "inbox",
        text: "inbox: \(count) \(count == 1 ? "item" : "items") for \(caller)"
          + (above == 0 ? "" : " (\(above) on this task)") + "\n"
      )
    ]
    sections += inbox.items.filter { !onTask($0) }.prefix(Self.items).map {
      BriefSection(id: "inbox", text: render($0, emitted: &emitted))
    }
    return (task, sections)
  }

  private func section(_ handoff: CommentDetails) -> BriefSection {
    let marker = "(handoff trimmed; \(command) task show \(current?.ref ?? ""))\n"
    let header =
      "handoff \(handoff.ref) by \(TaskError.shown(handoff.actor)) at \(handoff.createdAt)"
      + (handoff.resolvedAt == nil ? "" : ", resolved") + ":\n"
    return BriefBudget.capped(
      BriefSection(
        id: "handoff", text: header + Self.quoted(handoff.body), policy: .excerpt(marker: marker)),
      characters: BriefBudget.share(15, of: characters))
  }

  /// Post items name the current task; grouped items have no single task.
  private func onTask(_ item: InboxItem) -> Bool {
    item.task != nil && item.task == current?.ref
  }

  private func render(_ item: InboxItem, emitted: inout Set<String>) -> String {
    let next = item.next.filter { emitted.insert($0).inserted }.map { "next: " + $0 + "\n" }
    guard let ref = item.ref, let task = item.task, let author = item.author,
      let text = item.body
    else { return grouped(item) + next.joined() }
    let postKind = item.postKind ?? item.kind
    let kind = item.kind == "discussion" && postKind != item.kind ? " (\(postKind))" : ""
    let question = item.kind == "answer" ? item.replyTo.map { " to " + $0 } ?? "" : ""
    let masked = SecretGuard.redacted(text).trimmingCharacters(in: .newlines)
    let cut = masked.count > Self.excerpt
    let body = cut ? String(masked.prefix(Self.excerpt - 1)) + "…" : masked
    let header = "\(item.kind) \(ref)\(kind)\(question) on \(task)"
    let read = "\(command) task show \(shellWord(task)) --timeline"
    let marker = item.next.contains(read) ? "(trimmed)\n" : "(trimmed; \(read))\n"
    return header + " by \(TaskError.shown(author)):\n" + Self.quoted(body)
      + (cut ? marker : "")
      + (item.kind == "discussion" ? "clears on your next write to \(task)\n" : "")
      + next.joined()
  }

  /// A grouped or task-pointer item: its kind, task refs and context, then at most three
  /// task titles, quoted.
  private func grouped(_ item: InboxItem) -> String {
    let tasks = item.tasks ?? []
    let refs = tasks.isEmpty ? item.ref ?? "" : tasks.map(\.ref).joined(separator: ", ")
    let header =
      "\(item.kind) \(refs)"
      + (item.target.map { " on " + TaskError.shown($0) } ?? "")
      + (item.followUpAt.map { " due " + $0 } ?? "")
      + (item.author.map { " by " + TaskError.shown($0) } ?? "") + ":\n"
    let shown = tasks.prefix(Self.items).map { "\($0.ref): \($0.title)" }
    return header + (shown.isEmpty ? "" : Self.quoted(shown.joined(separator: "\n")))
      + (tasks.count > Self.items ? "(\(tasks.count - Self.items) more tasks)\n" : "")
  }

  /// Masks, then quotes every line so comment text cannot pose as brief structure.
  static func quoted(_ body: String) -> String {
    SecretGuard.redacted(body).trimmingCharacters(in: .newlines)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { "> " + TaskError.shown(String($0)) + "\n" }.joined()
  }
}
