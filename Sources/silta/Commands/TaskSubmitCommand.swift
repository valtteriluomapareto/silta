import ArgumentParser
import SiltaCore

struct TaskSubmitCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "submit", abstract: "Submit doing work for review and refresh its claim.")

  static let dataShape = TaskOutput.receiptShape

  @OptionGroup var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "The task reference.") var ref: String

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let text = try body.read(
      actor: context.environment.actor, command: "silta task submit " + shellWord(ref))
    return TaskOutput.receipt(
      try TaskService(environment: context.environment, workspace: global.ws)
        .submit(ref, body: text, allowSecret: body.allowSecret))
  }
}
