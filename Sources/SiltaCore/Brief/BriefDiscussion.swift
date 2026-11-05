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
      task += inbox.items.filter { $0.task == current.ref }.prefix(Self.items).map {
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
    let above = current.map { current in inbox.items.filter { $0.task == current.ref }.count } ?? 0
    var sections = [
      BriefSection(
        id: "inbox",
        text:
          "inbox: \(count) \(count == 1 ? "item" : "items") for \(caller) (scope: \(inbox.scope)"
          + (above == 0 ? "" : ", \(above) on this task") + ")\n"
      )
    ]
    sections += inbox.items.filter { $0.task != current?.ref }.prefix(Self.items).map {
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

  private func render(_ item: InboxItem, emitted: inout Set<String>) -> String {
    let kind = item.postKind == item.kind || item.kind != "discussion" ? "" : " (\(item.postKind))"
    let question = item.kind == "answer" ? item.replyTo.map { " to " + $0 } ?? "" : ""
    let masked = SecretGuard.redacted(item.body).trimmingCharacters(in: .newlines)
    let cut = masked.count > Self.excerpt
    let body = cut ? String(masked.prefix(Self.excerpt - 1)) + "…" : masked
    let header = "\(item.kind) \(item.ref)\(kind)\(question) on \(item.task)"
    let read = "\(command) task show \(shellWord(item.task)) --timeline"
    let marker = item.next.contains(read) ? "(trimmed)\n" : "(trimmed; \(read))\n"
    return header + " by \(TaskError.shown(item.author)):\n" + Self.quoted(body)
      + (cut ? marker : "")
      + (item.kind == "discussion" ? "clears on your next write to \(item.task)\n" : "")
      + item.next.filter { emitted.insert($0).inserted }.map { "next: " + $0 + "\n" }.joined()
  }

  /// Masks, then quotes every line so comment text cannot pose as brief structure.
  static func quoted(_ body: String) -> String {
    SecretGuard.redacted(body).trimmingCharacters(in: .newlines)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { "> " + TaskError.shown(String($0)) + "\n" }.joined()
  }
}
