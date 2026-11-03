/// What `silta schema` prints: the commands, the global flags and the error-code table
/// (spec §20.1). With every command's arguments and shape it is the detail; `index`
/// keeps only names and abstracts.
package struct SchemaDocument: Encodable, Sendable {
  /// The commands described.
  package var commands: [CommandSchema]
  /// Flags every command accepts.
  package var globalArguments: [ArgumentSchema]
  private var errors = ErrorCode.allCases.map(ErrorSchema.init)

  /// A detailed document for `commands` and `globalArguments`, with the error table.
  package init(commands: [CommandSchema], globalArguments: [ArgumentSchema]) {
    self.commands = commands
    self.globalArguments = globalArguments
  }

  /// The same document with only each command's name and abstract.
  package var index: SchemaDocument {
    var index = self
    index.commands = commands.map {
      var entry = $0
      entry.arguments = nil
      entry.data = nil
      return entry
    }
    return index
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
          "abstract": .string, "arguments": .optional(.array(argument)),
          "data": .optional(.any), "name": .string,
        ])),
      "errors": .array(
        .object(["agent_should": .string, "code": .string, "exit": .int, "next_by": .string])),
      "global_arguments": .array(argument),
    ])
  }()

  enum CodingKeys: String, CodingKey {
    case commands, errors
    case globalArguments = "global_arguments"
  }

  /// The index as text (spec §20.1).
  package var indexText: String {
    commands.map { "\($0.name)  \($0.abstract)\n" }.joined()
      + "details: silta schema <command>\n" + tail
  }

  /// The detail as text (spec §20.1).
  package var detailText: String {
    commands.map(\.text).joined(separator: "\n") + tail
  }

  private var tail: String {
    "\nglobal flags:\n" + globalArguments.map(\.line).joined() + "\nerror codes:\n"
      + ErrorCode.allCases.map {
        "  \($0.rawValue)  exit \($0.exitCode), next by \($0.nextBy.rawValue): \($0.agentShould)\n"
      }.joined() + "An error's own next_by can override its code's default.\n"
  }
}

/// One command in the schema.
package struct CommandSchema: Encodable, Sendable {
  /// The full name, e.g. `silta task ls`.
  package var name: String
  /// What the command does, in one line.
  package var abstract: String
  /// Its arguments, without the global flags; absent in the index.
  package var arguments: [ArgumentSchema]?
  /// The shape of its `--json` data; absent in the index.
  package var data: Shape?

  /// A command entry with full detail.
  package init(name: String, abstract: String, arguments: [ArgumentSchema], data: Shape) {
    self.name = name
    self.abstract = abstract
    self.arguments = arguments
    self.data = data
  }

  var text: String {
    let shape = data.flatMap { try? OutputRouter.json($0) } ?? "?"  // a Shape always encodes
    return "\(name)\n  \(abstract)\n" + (arguments ?? []).map(\.line).joined()
      + "  --json data: \(shape)\n"
  }
}

/// One row of the error-code table.
private struct ErrorSchema: Encodable, Sendable {
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
