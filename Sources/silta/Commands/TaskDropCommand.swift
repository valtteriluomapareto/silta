import ArgumentParser
import Foundation
import SiltaCore

struct TaskDropCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "drop", abstract: "Drop an open task and record why.")

  static let dataShape = TaskOutput.receiptShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "The task reference.") var ref: String

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    var commit = TaskCommit()
    commit.allowSecret = body.allowSecret
    let text = try body.read(
      actor: context.environment.actor, command: commit.command(ref, dropped: true),
      approved: global.approved)
    let closed = try await TaskService(
      environment: context.environment, workspace: global.ws, approved: global.approved,
      bodyFlag: body.flag
    )
    .close(
      ref, result: text, dropped: true, commit: commit,
      directory: URL(
        filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
    return TaskOutput.receipt(closed.result, approvalUsed: closed.approvalUsed)
      .reporting(context.taskWorkspace(global.ws))
  }
}
