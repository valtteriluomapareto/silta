import ArgumentParser
import Foundation
import SiltaCore

struct TaskAddCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "add", abstract: "Add a proposal; --start claims work requested by the human.")

  static let dataShape = TaskOutput.receiptShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(help: "The task title.") var title: String

  @Option(help: "Backlog priority: 1, 2 or 3.") var priority = 2

  @Flag(help: "Start and claim this requested work.") var start = false

  @Option(help: "The parent task reference; default is none.") var parent: String?

  @Option(help: "The app slug, or none for non-code work; omitted takes the parent's app.")
  var app: String?

  var appSlug: String? { app }

  @Option(name: .customLong("topic"), help: "An existing topic slug; default is none. Repeatable.")
  var topics: [String] = []

  @Option(help: "The source note: reference; default is none.") var from: String?

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
      environment: context.environment, workspace: global.ws, approved: global.approved,
      bodyFlag: body.flag
    )
    .add(
      draft,
      directory: URL(
        filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
    return TaskOutput.receipt(result, quiet: result.ref, approvalUsed: result.approvalUsed)
      .reporting(context.taskWorkspace(global.ws))
  }
}
