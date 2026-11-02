import ArgumentParser
import Foundation
import SiltaCore

/// The command tree as `silta schema` describes it, read from ArgumentParser's own
/// definitions so it can't drift from what the parser accepts (D31).
enum CommandCatalog {
  /// Every `OutputCommand` under `silta`, in definition order.
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
    let help = try JSONDecoder().decode(DumpedHelp.self, from: Data(type._dumpHelp().utf8))
    return (help.command.arguments ?? []).compactMap { argument in
      guard argument.shouldDisplay else { return nil }
      let names = (argument.names ?? []).map { $0.kind == "long" ? "--\($0.name)" : "-\($0.name)" }
      if names.contains(where: ["--help", "-h", "--version"].contains) { return nil }
      return ArgumentSchema(
        kind: argument.kind,
        names: argument.kind == "positional" ? ["<\(argument.valueName ?? "value")>"] : names,
        required: !argument.isOptional, repeating: argument.isRepeating,
        valueName: argument.kind == "flag" ? nil : argument.valueName,
        help: argument.abstract)
    }
  }

  private static func walk(_ command: any ParsableCommand.Type, path: String) -> [(
    any OutputCommand.Type, String
  )] {
    command.configuration.subcommands.flatMap { sub in
      let name = "\(path) \(sub._commandName)"
      let here = (sub as? any OutputCommand.Type).map { [($0, name)] } ?? []
      return here + walk(sub, path: name)
    }
  }
}

/// The part of ArgumentParser's `--experimental-dump-help` JSON that the schema uses.
private struct DumpedHelp: Decodable {
  struct Command: Decodable {
    let arguments: [Argument]?
  }

  struct Argument: Decodable {
    let kind: String
    let names: [Name]?
    let valueName: String?
    let abstract: String?
    let isOptional: Bool
    let isRepeating: Bool
    let shouldDisplay: Bool
  }

  struct Name: Decodable {
    let kind: String
    let name: String
  }

  let command: Command
}
