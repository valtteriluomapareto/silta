import ArgumentParser
import SiltaCore

struct TaskShowCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Read task bodies, claim, handoff and unresolved discussion.")

  static let dataShape = TaskOutput.detailShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The task reference.") var ref: String

  @Flag(help: "Include full discussion and attributed event history.") var timeline = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    // Keep one scope for the read, resume hint and shared task log resolver.
    let workspace = try context.workspace(global.ws)
    let task = try TaskService(environment: context.environment, workspace: workspace)
      .show(ref, timeline: timeline)
    let text = TaskOutput.detail(task, workspace: workspace)
    return CommandOutput(text: text, quiet: text, data: task).reporting(
      context.taskWorkspace(workspace))
  }
}
