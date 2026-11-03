import ArgumentParser
import SiltaCore

struct WsUseCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "use", abstract: "Select the current workspace.")

  static let dataShape = Shape.object(["workspace": .string])

  static let actsOnWorkspace = true

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The workspace slug to select.")
  var workspace: String

  var workspaceSlug: String? { workspace }

  func execute(_ context: CommandContext) throws -> CommandOutput {
    try WorkspaceSelection.use(workspace, in: context.environment.db)
    return CommandOutput(text: "Using workspace \(workspace).", data: Data(workspace: workspace))
  }

  private struct Data: Encodable {
    let workspace: String
  }
}
