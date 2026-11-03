import ArgumentParser
import SiltaCore

struct TaskShowCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Read a task's current bodies, claim and optional event timeline.")

  static let dataShape = TaskOutput.detailShape

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The task reference.") var ref: String

  @Flag(help: "Include the attributed event history.") var timeline = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let task = try TaskService(environment: context.environment, workspace: global.ws)
      .show(ref, timeline: timeline)
    let text = TaskOutput.detail(task)
    return CommandOutput(text: text, quiet: text, data: task)
  }
}
