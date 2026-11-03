import ArgumentParser
import SiltaCore

struct WsUseCommand: WorkspaceArgumentCommand {
  static let configuration = CommandConfiguration(
    commandName: "use", abstract: "Select the current workspace.")

  static let dataShape = Shape.object(["workspace": .string])

  static let workspaceSource = WorkspaceSource.argument

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The workspace slug to select.")
  var workspace: String

  var workspaceArgument: String? { workspace }

  func execute(_ context: CommandContext) throws -> CommandOutput {
    try WorkspaceSelection.use(workspace, in: context.environment.db)
    return CommandOutput(text: "Using workspace \(workspace).", data: Data(workspace: workspace))
      .reporting(workspace)
  }

  private struct Data: Encodable {
    let workspace: String
  }
}
