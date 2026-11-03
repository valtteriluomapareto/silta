import ArgumentParser
import SiltaCore

struct TaskBlockCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "block", abstract: "Record blockers; Silta sends nothing.")

  static let dataShape = Shape.object([
    "ref": .string, "status": .string, "follow_up_at": .optional(.string),
    "waiting": .optional(TaskOutput.waitingShape),
  ])

  @OptionGroup var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "The task reference.") var ref: String

  @Option(
    parsing: .upToNextOption, help: "Task, ext:party or url:http(s) blockers; Silta sends nothing.")
  var on: [String] = []

  @Option(help: "UTC YYYY-MM-DD or Nd, default 7d; today/0d is allowed.")
  var followUp: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    var input = TaskBlock(
      why: try body.read(
        actor: context.environment.actor,
        command: "silta task block " + shellWord(ref), approved: global.approved) ?? "")
    input.on = on
    input.followUp = followUp
    input.allowSecret = body.allowSecret
    let result = try TaskService(
      environment: context.environment, workspace: global.ws,
      approved: global.approved
    ).block(ref, input)
    var lines = ["\(result.ref) \(result.status)"]
    if let waiting = result.waiting { lines += TaskOutput.waitingLines(waiting) }
    if let day = result.followUpAt { lines.append("Follow-up: " + day) }
    for party in result.waiting?.on ?? [] where party.hasPrefix("ext:") {
      lines.append("Silta sends nothing; ask \(party): \(result.waiting?.why ?? "")")
    }
    return CommandOutput(
      text: lines.joined(separator: "\n"), data: result,
      warnings: result.warnings, approvalUsed: body.allowSecret)
  }
}

struct TaskUnblockCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "unblock", abstract: "Return a blocked batch to todo after an answer.")

  static let dataShape = Shape.object(["tasks": .array(TaskOutput.receiptShape)])

  @OptionGroup var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "One or more blocked task references.") var refs: [String]

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let command = "silta task unblock " + refs.map(shellWord).joined(separator: " ")
    let why = try body.read(
      actor: context.environment.actor, command: command, approved: global.approved)
    let tasks = try TaskService(
      environment: context.environment, workspace: global.ws,
      approved: global.approved
    ).unblock(refs, why: why, allowSecret: body.allowSecret)
    return CommandOutput(
      text: tasks.map { "\($0.ref) \($0.status)" }.joined(separator: "\n"),
      data: Data(tasks: tasks), warnings: tasks.flatMap(\.warnings), approvalUsed: body.allowSecret)
  }

  private struct Data: Encodable {
    let tasks: [TaskResult]
  }
}
