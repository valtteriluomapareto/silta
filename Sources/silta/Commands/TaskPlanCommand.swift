import ArgumentParser
import SiltaCore

struct TaskPlanCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan", abstract: "Store a plan revision or tick a top-level checkbox.")

  static let dataShape = Shape.object([
    "ref": .string, "plan_rev": .int, "plan": .string,
  ])

  @OptionGroup var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "The task reference.") var ref: String

  @Option(help: "Require the current revision to match this nonnegative value.")
  var ifRev: Int?

  @Option(help: "Top-level checkbox number, from 1; checked entries count, fenced examples do not.")
  var step: Int?

  @Flag(help: "Mark the selected checkbox done.") var done = false

  @Flag(help: "Mark the selected checkbox undone.") var undo = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let service = TaskService(
      environment: context.environment, workspace: global.ws, approved: global.approved)
    let result: TaskPlanResult
    if let step {
      guard done != undo, body.message == nil, body.file == nil, !body.allowSecret else {
        throw TaskError.invalid(
          "Use --step N with exactly one of --done/--undo, and no body or --allow-secret.")
      }
      result = try service.tick(ref, step: step, done: done, ifRevision: ifRev)
    } else {
      guard !done, !undo else {
        throw TaskError.invalid("--done and --undo require --step N.")
      }
      let text = try body.read(
        actor: context.environment.actor, command: TaskService.planCommand(ref, ifRevision: ifRev),
        approved: global.approved)
      guard let text else {
        throw TaskError.invalid("Supply -m or -F for a revision, or --step N --done|--undo.")
      }
      result = try service.plan(ref, text: text, ifRevision: ifRev, allowSecret: body.allowSecret)
    }
    return CommandOutput(
      text: "\(result.ref) plan revision \(result.planRev)\n\(result.plan)", data: result,
      warnings: result.warnings, approvalUsed: body.allowSecret)
  }
}
