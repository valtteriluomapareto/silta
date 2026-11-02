/// What `silta schema` prints: every command, its arguments and `--json` data shape,
/// the global flags, and the error-code table (spec §20.1).
package struct SchemaDocument: Encodable, Sendable {
  /// The commands described.
  package var commands: [CommandSchema]
  /// Flags every command accepts.
  package var globalArguments: [ArgumentSchema]

  /// A document for `commands` and `globalArguments`, with the full error table.
  package init(commands: [CommandSchema], globalArguments: [ArgumentSchema]) {
    self.commands = commands
    self.globalArguments = globalArguments
  }

  /// The shape of this document's JSON, which `silta schema` publishes for itself.
  package static let shape: Shape = {
    let argument = Shape.object([
      "help": .optional(.string), "kind": .string, "names": .array(.string),
      "repeating": .bool, "required": .bool, "value_name": .optional(.string),
    ])
    return .object([
      "commands": .array(
        .object([
          "abstract": .string, "arguments": .array(argument), "data": .any, "name": .string,
        ])),
      "envelope": .int,
      "errors": .array(
        .object(["agent_should": .string, "code": .string, "exit": .int, "next_by": .string])),
      "global_arguments": .array(argument),
    ])
  }()

  enum CodingKeys: String, CodingKey {
    case commands, envelope, errors
    case globalArguments = "global_arguments"
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(commands, forKey: .commands)
    try container.encode(Envelope.version, forKey: .envelope)
    try container.encode(ErrorCode.allCases.map(ErrorSchema.init), forKey: .errors)
    try container.encode(globalArguments, forKey: .globalArguments)
  }

  /// The text form (spec §20.1).
  package var text: String {
    var out = commands.map(\.text).joined(separator: "\n")
    out += "\nglobal flags:\n" + globalArguments.map(\.line).joined()
    out += "\nerror codes:\n"
    out += ErrorCode.allCases.map {
      "  \($0.rawValue)  exit \($0.exitCode), next by \($0.nextBy.rawValue): \($0.agentShould)\n"
    }.joined()
    return out
  }
}

/// One command in the schema.
package struct CommandSchema: Encodable, Sendable {
  /// The full name, e.g. `silta task ls`.
  package var name: String
  /// What the command does, in one line.
  package var abstract: String
  /// Its arguments, without the global flags.
  package var arguments: [ArgumentSchema]
  /// The shape of its `--json` data.
  package var data: Shape

  /// A command entry.
  package init(name: String, abstract: String, arguments: [ArgumentSchema], data: Shape) {
    self.name = name
    self.abstract = abstract
    self.arguments = arguments
    self.data = data
  }

  var text: String {
    let shape = (try? OutputRouter.json(data)) ?? "?"  // a Shape always encodes
    return "\(name)\n  \(abstract)\n" + arguments.map(\.line).joined() + "  --json data: \(shape)\n"
  }
}

/// One argument of a command.
package struct ArgumentSchema: Encodable, Sendable {
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

  enum CodingKeys: String, CodingKey {
    case kind, names, required, repeating, help
    case valueName = "value_name"
  }

  var line: String {
    let value = kind == "option" ? valueName.map { " <\($0)>" } ?? "" : ""
    let flags = (required ? "required" : "optional") + (repeating ? ", repeating" : "")
    return "  \(names.joined(separator: ", "))\(value)  \(flags): \(help ?? "")\n"
  }
}

/// One row of the error-code table.
struct ErrorSchema: Encodable {
  let code: String
  let exit: Int32
  let nextBy: String
  let agentShould: String

  init(_ code: ErrorCode) {
    self.code = code.rawValue
    exit = code.exitCode
    nextBy = code.nextBy.rawValue
    agentShould = code.agentShould
  }

  enum CodingKeys: String, CodingKey {
    case code, exit
    case nextBy = "next_by"
    case agentShould = "agent_should"
  }
}
