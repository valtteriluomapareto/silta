import ArgumentParser
import Foundation
import SiltaCore

struct TaskDoneCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "done", abstract: "Complete a task with its result and optional app commit.")

  static let dataShape = TaskOutput.receiptShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "The task reference.") var ref: String

  @Option(
    help: .init(
      "Record this commit from the task's repository; "
        + "default is attribution from the repository."))
  var sha: String?

  @Flag(help: "Skip commit attribution.") var noSha = false

  @Flag(help: "Override an unmet review gate; human-only then; a result is optional.")
  var force = false

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    var commit = TaskCommit()
    commit.sha = sha
    commit.noSHA = noSha
    commit.force = force
    commit.allowSecret = body.allowSecret
    let text = try body.read(
      actor: context.environment.actor, command: commit.command(ref, dropped: false),
      approved: global.approved)
    let closed = try await TaskService(
      environment: context.environment, workspace: global.ws, approved: global.approved,
      bodyFlag: body.flag
    )
    .close(
      ref, result: text, commit: commit,
      directory: URL(
        filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
    return TaskOutput.receipt(closed.result, approvalUsed: closed.approvalUsed)
      .reporting(context.taskWorkspace(global.ws))
  }
}
