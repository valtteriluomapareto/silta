import ArgumentParser
import SiltaCore

/// The command tree as `silta schema` describes it, read from ArgumentParser's own
/// definitions so it can't drift from what the parser accepts (D31).
enum CommandCatalog {
  /// Every visible `OutputCommand` under `silta`, in definition order.
  static func commands() throws -> [CommandSchema] {
    let global = try Set(arguments(of: GlobalOptions.self).flatMap(\.names))
    return try walk(SiltaCommand.self, path: "silta").map { type, name in
      CommandSchema(
        name: name, abstract: type.configuration.abstract,
        arguments: try arguments(of: type).filter { global.isDisjoint(with: $0.names) },
        data: type.dataShape)
    }
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
      let here = (sub as? any OutputCommand.Type).map { [($0, name)] } ?? []
      return here + walk(sub, path: name)
    }
  }
}
