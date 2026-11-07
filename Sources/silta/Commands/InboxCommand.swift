import ArgumentParser
import SiltaCore

struct InboxCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "inbox", abstract: "Read current local attention without marking it read.",
    discussion: "Human inboxes include grouped blockers, proposals and promoted task pointers. "
      + "Tracker status is not refreshed. --for me means human:<USER>, independent of the caller. "
      + "ask human: is a confirmation instruction, not an executable command. "
      + "See `silta guide questions` for relay and approval rules. Reads never clear attention.")
  static let workspaceSource = WorkspaceSource.option
  static let dataShape = Shape.object([
    "scope": .string, "actor": .string, "remaining": .int, "more": .optional(.string),
    "items": .array(
      .object([
        "kind": .string, "next": .array(.string), "ref": .optional(.string),
        "task": .optional(.string), "author": .optional(.string), "body": .optional(.string),
        "created_at": .optional(.string), "post_kind": .optional(.string),
        "reply_to": .optional(.string), "relayed_by": .optional(.array(.string)),
        "target": .optional(.string), "follow_up_at": .optional(.string),
        "tasks": .optional(
          .array(
            .object([
              "ref": .string, "title": .string, "why": .optional(.string),
              "on": .optional(.array(.string)), "follow_up_at": .optional(.string),
              "external_ref": .optional(.string),
            ]))),
      ])),
  ])

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Option(name: .customLong("for"), help: "Complete actor or me; defaults to the caller.")
  var target: String?
  @Flag(help: "Show every item, including proposals older than 14 days.")
  var all = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    let result = try TaskService(environment: context.environment, workspace: workspace)
      .inbox(for: target, all: all)
    var lines = [
      result.items.isEmpty
        ? "No attention for \(result.actor)."
        : result.actor + " attention"
    ]
    lines.append(
      "Scope: current local attention; tracker status is not refreshed.")
    lines += result.items.map(Self.detail)
    if let more = result.more { lines.append("\(result.remaining) more: " + more) }
    let text = lines.joined(separator: "\n")
    return CommandOutput(text: text, quiet: text, data: result).reporting(workspace)
  }

  private static func detail(_ item: InboxItem) -> String {
    if let tasks = item.tasks { return groupedDetail(item, tasks: tasks) }
    guard let ref = item.ref, let task = item.task, let author = item.author,
      let bodyText = item.body, let postKind = item.postKind
    else { return "" }
    let label =
      item.kind == "answer"
      ? "answer to " + (item.replyTo ?? ref)
      : item.kind == "discussion" ? "discussion (\(postKind))" : item.kind
    var lines = ["\(ref) \(label) on \(task) by \(author)"]
    var body = bodyText
    if body.last?.isNewline == true { body.removeLast() }
    lines += body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map { $0.isEmpty ? ">" : "> " + $0 }
    if let relayers = item.relayedBy {
      lines.append("Agent answers awaiting confirmation from: " + relayers.joined(separator: ", "))
    }
    if item.kind == "discussion" {
      lines.append("clears on the claimer's next write to " + task)
    }
    lines += item.next.map { "next: " + $0 }
    return lines.joined(separator: "\n")
  }

  private static func groupedDetail(_ item: InboxItem, tasks: [InboxTask]) -> String {
    let refs = tasks.map(\.ref).joined(separator: ", ")
    let heading: String
    switch item.kind {
    case "ready": heading = refs + " ready to unblock"
    case "replan": heading = refs + " blocker dropped: re-plan"
    case "due": heading = (item.target ?? refs) + " follow-up due " + (item.followUpAt ?? "")
    case "proposal": heading = refs + " proposal by " + (item.author ?? "")
    default: heading = refs + " promoted; change it in its tracker"
    }
    var lines = [heading]
    for task in tasks {
      lines += indented(task.ref + ": " + task.title)
      if let on = task.on {
        lines += indented("waiting on: " + (on.isEmpty ? "an answer" : on.joined(separator: ", ")))
      }
      if let why = task.why { lines += indented("ask: " + why) }
      if let day = task.followUpAt { lines += indented("follow-up: " + day) }
      if let external = task.externalRef { lines += indented("tracker: " + external) }
    }
    lines += item.next.map { "next: " + $0 }
    return lines.joined(separator: "\n")
  }

  private static func indented(_ text: String) -> [String] {
    text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { "  " + $0 }
  }

}
