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

  @Flag(help: "Start and claim this requested work.") var start = false

  @Option(help: "The parent task reference.") var parent: String?

  @Option(help: "The explicit app slug; omitted means non-code work.") var app: String?

  @Option(name: .customLong("topic"), help: "An existing topic slug; repeat for several topics.")
  var topics: [String] = []

  @Option(help: "The source note: reference.") var from: String?

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    var draft = TaskDraft(title: title)
    draft.description =
      try body.read(actor: context.environment.actor, command: "silta task add") ?? ""
    draft.allowSecret = body.allowSecret
    draft.start = start
    draft.parent = parent
    draft.app = app
    draft.topics = topics
    draft.source = from
    let result = try await TaskService(environment: context.environment, workspace: global.ws)
      .add(
        draft,
        directory: URL(
          filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
    return TaskOutput.receipt(result)
  }
}
