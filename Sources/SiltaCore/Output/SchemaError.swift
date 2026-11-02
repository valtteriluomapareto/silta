/// `silta schema <command>` named no command.
package enum SchemaError: CodedError {
  /// No command starts with `name`; `known` are the commands that exist.
  case unknownCommand(String, known: [String])

  package var code: ErrorCode { .invalid }

  package var message: String {
    switch self {
    case .unknownCommand(let name, let known):
      "No command '\(name)'; commands: \(known.joined(separator: ", "))"
    }
  }

  package var next: [String] { ["silta schema"] }
}
