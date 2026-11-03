import ArgumentParser
import SiltaCore

struct WsShowCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "show", abstract: "Print the current workspace YAML without editing it.")

  static let dataShape = Shape.object(["workspace": .string, "yaml": .string])

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The workspace slug; defaults to the current workspace.")
  var workspace: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let store = context.environment.db
    let slug = try WorkspaceSelection.resolve(workspace ?? global.ws, in: store)
    let yaml = try store.read { try WorkspaceConfig.render(from: $0, slug: slug) }
    return CommandOutput(text: yaml, data: Data(workspace: slug, yaml: yaml))
  }

  private struct Data: Encodable {
    let workspace: String
    let yaml: String
  }
}
