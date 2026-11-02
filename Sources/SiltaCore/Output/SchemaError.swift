/// `silta schema <command>` named a command that doesn't exist.
package enum SchemaError: CodedError {
  /// No command has this full name, e.g. `silta nope`.
  case unknownCommand(String)

  package var code: ErrorCode { .notFound }

  package var message: String {
    switch self {
    case .unknownCommand(let name): "No command '\(name)'"
    }
  }

  package var next: [String] { ["silta schema"] }
}
