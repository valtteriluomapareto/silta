import ArgumentParser
import SiltaCore

/// `silta schema [<command>…]`: every command, its flags, its `--json` data shape and
/// the error-code table (spec §20.1).
struct SchemaCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "schema",
    abstract: "Describe every command, its flags, its --json data and the error codes."
  )

  static let dataShape = SchemaDocument.shape

  @OptionGroup var global: GlobalOptions

  @Argument(help: "Only this command, e.g. `schema` or `task ls`.")
  var command: [String] = []

  func execute(_ context: CommandContext) throws -> CommandOutput {
    var commands = try CommandCatalog.commands()
    if !command.isEmpty {
      let name = (["silta"] + command).joined(separator: " ")
      commands = commands.filter { $0.name == name }
      guard !commands.isEmpty else { throw SchemaError.unknownCommand(name) }
    }
    let document = SchemaDocument(
      commands: commands, globalArguments: try CommandCatalog.arguments(of: GlobalOptions.self))
    return CommandOutput(text: document.text, data: document)
  }
}
