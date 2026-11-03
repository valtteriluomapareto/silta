import ArgumentParser
import SiltaCore

struct WsListCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls", abstract: "List workspaces; ask a human to run silta ws edit if empty.")

  static let dataShape = Shape.object([
    "workspaces": .array(
      .object([
        "slug": .string, "name": .string, "task_prefix": .string,
      ]))
  ])

  @OptionGroup var global: GlobalOptions

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspaces = try WorkspaceSelection.list(in: context.environment.db)
    let text =
      workspaces.isEmpty
      ? "No workspaces. Ask human: silta ws edit"
      : workspaces.map { "\($0.slug)\t\($0.name)\t\($0.taskPrefix)" }.joined(separator: "\n")
    return CommandOutput(text: text, data: Data(workspaces: workspaces))
  }

  private struct Data: Encodable {
    let workspaces: [WorkspaceSummary]
  }
}
