import ArgumentParser
import Foundation
import SiltaCore

struct TaskAddCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "add", abstract: "Add a proposal; --start claims work requested by the human.")

  static let dataShape = TaskOutput.receiptShape

  @OptionGroup var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "The task title.") var title: String

  @Option(help: "Backlog priority: 1, 2 (default) or 3.") var priority = 2

  @Flag(help: "Start and claim this requested work.") var start = false

  @Option(help: "The parent task reference.") var parent: String?

  @Option(help: "The explicit app slug; omitted means non-code work.") var app: String?

  @Option(name: .customLong("topic"), help: "An existing topic slug; repeat for several topics.")
  var topics: [String] = []

  @Option(help: "The source note: reference.") var from: String?

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    var draft = TaskDraft(title: title)
    draft.priority = priority
    draft.allowSecret = body.allowSecret
    draft.start = start
    draft.parent = parent
    draft.app = app
    draft.topics = topics
    draft.source = from
    draft.description =
      try body.read(
        actor: context.environment.actor, command: draft.command + " '<title>'",
        approved: global.approved) ?? ""
    let result = try await TaskService(
      environment: context.environment, workspace: global.ws, approved: global.approved
    )
    .add(
      draft,
      directory: URL(
        filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
    return TaskOutput.receipt(result, quiet: result.ref, approvalUsed: body.allowSecret)
  }
}
