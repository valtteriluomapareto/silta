import ArgumentParser
import SiltaCore

struct WsListCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls", abstract: "List workspaces; ask in chat before editing configuration.")

  static let dataShape = Shape.object([
    "workspaces": .array(
      .object([
        "slug": .string, "name": .string, "task_prefix": .string,
      ]))
  ])

  static let workspaceSource = WorkspaceSource.none

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspaces = try WorkspaceSelection.list(in: context.environment.db)
    let text =
      workspaces.isEmpty
      ? "No workspaces. Ask in chat, then: silta ws edit -F <file>"
        + " --approved \"<the human's words>\""
      : workspaces.map { "\($0.slug)\t\($0.name)\t\($0.taskPrefix)" }.joined(separator: "\n")
    return CommandOutput(text: text, quiet: text, data: Data(workspaces: workspaces))
  }

  private struct Data: Encodable {
    let workspaces: [WorkspaceSummary]
  }
}
