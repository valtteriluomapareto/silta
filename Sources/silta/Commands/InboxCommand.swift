import ArgumentParser
import SiltaCore

struct InboxCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "inbox", abstract: "Read current discussion attention without marking it read.",
    discussion: "Discussion attention only: grouped blockers, proposals and promoted attention "
      + "are not yet included. --for me means human:<USER>, independent of the caller. "
      + "Items offer alternative actions. After confirming a human's answer in chat, "
      + "the claimer accepts the relay or the relayer resolves with -m explaining it. "
      + "A relay never supplies approval words. Reads never clear attention.")
  static let workspaceSource = WorkspaceSource.option
  static let dataShape = Shape.object([
    "actor": .string, "remaining": .int, "more": .optional(.string),
    "items": .array(
      .object([
        "kind": .string, "ref": .string, "task": .string, "author": .string, "body": .string,
        "created_at": .string, "next": .array(.string),
      ])),
  ])

  @OptionGroup var global: GlobalOptions
  @Option(name: .customLong("for"), help: "Complete actor or me; defaults to the caller.")
  var target: String?
  @Flag(help: "Show all discussion items beyond the default cap of 12.") var all = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    let result = try TaskService(environment: context.environment, workspace: workspace)
      .inbox(for: target, all: all)
    var lines = [result.actor + " discussion attention"]
    for item in result.items {
      lines.append("\(item.ref) \(item.kind) on \(item.task) by \(item.author)")
      lines += item.body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        .map { $0.isEmpty ? ">" : "> " + $0 }
      lines += item.next.map { "next: " + $0 }
    }
    if result.items.isEmpty { lines = ["No discussion attention for \(result.actor)."] }
    if let more = result.more { lines.append("\(result.remaining) more: " + more) }
    let text = lines.joined(separator: "\n")
    return CommandOutput(text: text, quiet: text, data: result).reporting(workspace)
  }
}
