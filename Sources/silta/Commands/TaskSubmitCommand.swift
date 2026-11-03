import ArgumentParser
import SiltaCore

struct TaskSubmitCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "submit", abstract: "Submit doing work for review and refresh its claim.")

  static let dataShape = TaskOutput.receiptShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The task reference.") var ref: String

  func execute(_ context: CommandContext) throws -> CommandOutput {
    TaskOutput.receipt(
      try TaskService(environment: context.environment, workspace: global.ws).submit(ref)
    ).reporting(context.taskWorkspace(global.ws))
  }
}
