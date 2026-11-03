import ArgumentParser
import Foundation
import SiltaCore

struct TaskStartCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "start", abstract: "Claim a todo task for this exact actor and session.")

  static let dataShape = TaskOutput.receiptShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The task reference.") var ref: String

  @Flag(help: "Override another actor's claim (human-only).") var steal = false

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    TaskOutput.receipt(
      try await TaskService(
        environment: context.environment, workspace: global.ws, approved: global.approved
      )
      .start(
        ref, steal: steal,
        directory: URL(
          filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)),
      approvalUsed: steal
    ).reporting(context.taskWorkspace(global.ws))
  }
}
