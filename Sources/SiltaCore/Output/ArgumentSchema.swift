import Foundation

/// One argument of a command, as `silta schema` lists it (spec §20.1).
package struct ArgumentSchema: Encodable, Equatable, Sendable {
  /// `flag`, `option` or `positional`.
  package var kind: String
  /// `--json`, `-m`, or `<value_name>` for a positional.
  package var names: [String]
  /// Whether the call fails without it.
  package var required: Bool
  /// Whether it may be given more than once.
  package var repeating: Bool
  /// The value's placeholder, for options and positionals.
  package var valueName: String?
  /// What it does.
  package var help: String?

  /// An argument entry.
  package init(
    kind: String, names: [String], required: Bool, repeating: Bool, valueName: String?,
    help: String?
  ) {
    self.kind = kind
    self.names = names
    self.required = required
    self.repeating = repeating
    self.valueName = valueName
    self.help = help
  }

  /// The visible arguments in ArgumentParser's dump-help JSON (`_dumpHelp()`, D31),
  /// without `--help` and `--version`.
  package static func list(dumpedHelp: String) throws -> [ArgumentSchema] {
    let help = try JSONDecoder().decode(DumpedHelp.self, from: Data(dumpedHelp.utf8))
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

  enum CodingKeys: String, CodingKey {
    case kind, names, required, repeating, help
    case valueName = "value_name"
  }

  var line: String {
    let value = kind == "option" ? valueName.map { " <\($0)>" } ?? "" : ""
    let flags = (required ? "required" : "optional") + (repeating ? ", repeating" : "")
    return "  \(names.joined(separator: ", "))\(value)  \(flags)" + (help.map { ": \($0)" } ?? "")
      + "\n"
  }
}

/// The part of ArgumentParser's dump-help JSON the schema reads.
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
