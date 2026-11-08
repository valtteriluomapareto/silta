import ArgumentParser
import SiltaCore

struct WsUseCommand: WorkspaceArgumentCommand {
  static let configuration = CommandConfiguration(
    commandName: "use", abstract: "Set the default workspace outside registered repositories.")

  static let dataShape = Shape.object(["workspace": .string])

  static let workspaceSource = WorkspaceSource.argument

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @Argument(help: "The workspace slug to use outside registered repositories.")
  var workspace: String

  var workspaceArgument: String? { workspace }

  func execute(_ context: CommandContext) throws -> CommandOutput {
    try WorkspaceSelection.use(workspace, in: context.environment.db)
    return CommandOutput(
      text: "Default workspace outside registered repositories: \(workspace).",
      data: Data(workspace: workspace)
    )
    .reporting(workspace)
  }

  private struct Data: Encodable {
    let workspace: String
  }
}
