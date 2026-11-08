import ArgumentParser
import SiltaCore

struct WsShowCommand: WorkspaceArgumentCommand {
  static let configuration = CommandConfiguration(
    commandName: "show", abstract: "Print the selected workspace YAML without editing it.")

  static let dataShape = Shape.object(["workspace": .string, "yaml": .string])

  static let workspaceSource = WorkspaceSource.argument

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @Argument(help: "The workspace slug; defaults to repository location, then the saved default.")
  var workspace: String?

  var workspaceArgument: String? { workspace }

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let store = context.environment.db
    let slug = try context.workspace(workspace ?? global.ws)
    let yaml = try store.read { try WorkspaceConfig.render(from: $0, slug: slug) }
    return CommandOutput(text: yaml, quiet: yaml, data: Data(workspace: slug, yaml: yaml))
      .reporting(slug)
  }

  private struct Data: Encodable {
    let workspace: String
    let yaml: String
  }
}
