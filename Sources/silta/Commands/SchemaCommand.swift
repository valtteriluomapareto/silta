import ArgumentParser
import SiltaCore

/// `silta schema [<command>…]`: an index of the commands, or full detail for the
/// named ones, plus the global flags and the error-code table (spec §20.1).
struct SchemaCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "schema",
    abstract: "Describe the commands, their flags, their --json data and the error codes."
  )

  static let dataShape = SchemaDocument.shape

  static let workspaceSource = WorkspaceSource.none

  @OptionGroup var global: GlobalOptions

  @Argument(help: "A command's name, e.g. `task ls`; a group's name lists the group.")
  var command: [String] = []

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let all = try CommandCatalog.commands()
    let global = try CommandCatalog.arguments(of: GlobalOptions.self)
    let words = command.first == "silta" ? Array(command.dropFirst()) : command
    if words.isEmpty {
      let index = SchemaDocument(commands: all, globalArguments: global).index
      return CommandOutput(text: index.indexText, data: index)
    }
    let selected = all.filter { entry in
      let entryWords = entry.name.split(separator: " ").dropFirst().map(String.init)
      return entryWords.starts(with: words)
    }
    guard !selected.isEmpty else {
      throw SchemaError.unknownCommand(
        (["silta"] + words).joined(separator: " "), known: all.map(\.name))
    }
    let detail = SchemaDocument(commands: selected, globalArguments: global)
    return CommandOutput(text: detail.detailText, data: detail)
  }
}
