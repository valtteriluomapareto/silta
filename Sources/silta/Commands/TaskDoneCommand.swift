import ArgumentParser
import Foundation
import SiltaCore

struct TaskDoneCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "done", abstract: "Complete a task with its result and optional app commit.")

  static let dataShape = TaskOutput.receiptShape

  @OptionGroup var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "The task reference.") var ref: String

  @Option(help: "Record this commit from the task's repository.") var sha: String?

  @Flag(help: "Skip commit attribution.") var noSha = false

  @Flag(help: "Override the review gate (human-only; provide the result with -F <file>).")
  var force = false

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    if force {
      try context.environment.actor.requireHuman(
        command: "silta task done " + shellWord(ref) + " --force -F <file>")
    }
    let text = try body.read(
      actor: context.environment.actor, command: "silta task done " + shellWord(ref))
    var commit = TaskCommit()
    commit.sha = sha
    commit.noSHA = noSha
    commit.force = force
    commit.allowSecret = body.allowSecret
    return TaskOutput.receipt(
      try await TaskService(environment: context.environment, workspace: global.ws)
        .close(
          ref, result: text, commit: commit,
          directory: URL(
            filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)))
  }
}
