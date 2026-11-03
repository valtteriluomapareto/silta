import ArgumentParser
import Foundation
import SiltaCore

struct TaskDoneCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "done", abstract: "Complete a task with its result and optional app commit.")

  static let dataShape = TaskOutput.receiptShape

  static let actsOnWorkspace = true

  @OptionGroup var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "The task reference.") var ref: String

  @Option(help: "Record this commit from the task's repository.") var sha: String?

  @Flag(help: "Skip commit attribution.") var noSha = false

  @Flag(help: "Override the review gate (human-only; provide the result with -F <file>).")
  var force = false

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    var commit = TaskCommit()
    commit.sha = sha
    commit.noSHA = noSha
    commit.force = force
    commit.allowSecret = body.allowSecret
    if force {
      try context.environment.actor.requireHuman(
        command: commit.command(ref, dropped: false)
          + (body.allowSecret ? " --allow-secret" : "") + " -F <file>", approved: global.approved)
    }
    let text = try body.read(
      actor: context.environment.actor, command: commit.command(ref, dropped: false),
      approved: global.approved)
    return TaskOutput.receipt(
      try await TaskService(
        environment: context.environment, workspace: global.ws, approved: global.approved
      )
      .close(
        ref, result: text, commit: commit,
        directory: URL(
          filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)),
      approvalUsed: force || body.allowSecret)
  }
}
