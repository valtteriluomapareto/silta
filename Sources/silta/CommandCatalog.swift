import ArgumentParser
import SiltaCore

/// The command tree as `silta schema` describes it, read from ArgumentParser's own
/// definitions so it can't drift from what the parser accepts (D31).
enum CommandCatalog {
  /// Every visible `OutputCommand` under `silta`, in definition order.
  static func commands() throws -> [CommandSchema] {
    let global = try Set(arguments(of: GlobalOptions.self).flatMap(\.names))
    var commands = try walk(SiltaCommand.self, path: "silta").map { type, name in
      CommandSchema(
        name: name, abstract: type.configuration.abstract,
        arguments: try arguments(of: type).filter { global.isDisjoint(with: $0.names) },
        data: type.dataShape)
    }
    commands.append(
      CommandSchema(
        name: "silta help refs", abstract: ReferenceHelpCommand.configuration.abstract,
        arguments: [], data: ReferenceHelpCommand.dataShape))
    return commands
  }

  /// The arguments `type` declares, without `--help` and `--version`.
  static func arguments(of type: any ParsableArguments.Type) throws -> [ArgumentSchema] {
    try ArgumentSchema.list(dumpedHelp: type._dumpHelp())
  }

  private static func walk(_ command: any ParsableCommand.Type, path: String) -> [(
    any OutputCommand.Type, String
  )] {
    command.configuration.subcommands.filter { $0.configuration.shouldDisplay }.flatMap { sub in
      let name = "\(path) \(sub._commandName)"
      // A hidden default supplies the group's existing data/argument contract.
      let output =
        (sub as? any OutputCommand.Type)
        ?? (sub.configuration.defaultSubcommand.flatMap {
          $0.configuration.shouldDisplay ? nil : $0 as? any OutputCommand.Type
        })
      let here = output.map { [($0, name)] } ?? []
      return here + walk(sub, path: name)
    }
  }
}
