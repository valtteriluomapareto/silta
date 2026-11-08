import ArgumentParser
import SiltaCore

struct TaskBlockCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "block", abstract: "Record blockers; Silta sends nothing.",
    discussion: "After a handoff: silta task block AC-2 --on AC-1 -m \"Waiting for API.\"")

  static let dataShape = Shape.object([
    "ref": .string, "status": .string, "follow_up_at": .optional(.string),
    "waiting": .optional(TaskOutput.waitingShape),
  ])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "The task reference.") var ref: String

  @Option(
    parsing: .upToNextOption,
    help: "Task, ext:party or url:http(s) blockers; default is none. Silta sends nothing.")
  var on: [String] = []

  @Option(help: "UTC YYYY-MM-DD or Nd, default 7d; today/0d is allowed.")
  var followUp: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    var input = TaskBlock(why: "")
    input.on = on
    input.followUp = followUp
    input.allowSecret = body.allowSecret
    input.why =
      try body.read(
        actor: context.environment.actor,
        command: input.command(ref), approved: global.approved) ?? ""
    let result = try TaskService(
      environment: context.environment, workspace: global.ws,
      approved: global.approved, bodyFlag: body.flag
    ).block(ref, input)
    var lines = ["\(result.ref) \(result.status)"]
    if let waiting = result.waiting { lines += TaskOutput.waitingLines(waiting) }
    if let day = result.followUpAt { lines.append("Follow-up: " + day) }
    // The -m is the ask to the parties this call names, not to earlier ones.
    let named = on.filter { $0.hasPrefix("ext:") }
    for party in result.waiting?.on ?? [] where named.contains(party) {
      lines.append("Silta sends nothing; ask \(party): \(result.waiting?.why ?? "")")
    }
    return CommandOutput(
      text: lines.joined(separator: "\n"), data: result,
      warnings: result.warnings, approvalUsed: body.allowSecret
    ).reporting(context.taskWorkspace(global.ws))
  }
}

struct TaskUnblockCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "unblock",
    abstract: "Return a blocked batch to todo; an open blocker needs the human's go-ahead.")

  static let dataShape = Shape.object(["tasks": .array(TaskOutput.receiptShape)])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "One or more blocked task references.") var refs: [String]

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let command =
      "silta task unblock "
      + refs.map { shellWord(SecretGuard.redacted($0)) }.joined(separator: " ")
    let why = try body.read(
      actor: context.environment.actor, command: command, approved: global.approved)
    let result = try TaskService(
      environment: context.environment, workspace: global.ws,
      approved: global.approved, bodyFlag: body.flag
    ).unblock(refs, why: why, allowSecret: body.allowSecret)
    let tasks = result.tasks
    return CommandOutput(
      text: tasks.map { "\($0.ref) \($0.status)" }.joined(separator: "\n"),
      data: Data(tasks: tasks), warnings: tasks.flatMap(\.warnings),
      approvalUsed: result.approvalUsed
    ).reporting(context.taskWorkspace(global.ws))
  }

  private struct Data: Encodable {
    let tasks: [TaskResult]
  }
}
