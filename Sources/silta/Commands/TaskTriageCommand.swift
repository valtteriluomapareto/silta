import ArgumentParser
import SiltaCore

struct TaskTriageCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "triage",
    abstract: "Accept or drop proposals in one approved batch.")

  static let dataShape = Shape.object(["tasks": .array(TaskOutput.receiptShape)])

  @OptionGroup var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Option(parsing: .upToNextOption, help: "Proposal refs to accept; repeat or list several.")
  var accept: [String] = []

  @Option(parsing: .upToNextOption, help: "Proposal refs to drop; repeat or list several.")
  var drop: [String] = []

  @Option(help: "Priority for accepted proposals: 1, 2 or 3; without it they keep their own.")
  var priority: Int?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    var batch = TaskTriage()
    batch.accept = accept
    batch.drop = drop
    batch.priority = priority
    batch.allowSecret = body.allowSecret
    batch.why = body.file != nil || body.message != nil ? "" : nil
    try context.environment.actor.requireHuman(
      command: batch.retryCommand,
      approved: global.approved)
    batch.why = try body.read(
      actor: context.environment.actor, command: batch.command,
      approved: global.approved)
    let tasks = try TaskService(
      environment: context.environment, workspace: global.ws,
      approved: global.approved, bodyFlag: body.flag
    ).triage(batch)
    return CommandOutput(
      text: tasks.map { "\($0.ref) \($0.status)" }.joined(separator: "\n"),
      data: Data(tasks: tasks), warnings: tasks.flatMap(\.warnings), approvalUsed: true)
  }

  private struct Data: Encodable {

    let tasks: [TaskResult]

  }
}
