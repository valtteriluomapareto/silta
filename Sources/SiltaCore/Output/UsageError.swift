/// A call that doesn't parse (`usage`) or whose values don't fit (`invalid`).
package enum UsageError: CodedError {
  /// The arguments don't parse; `command` is the command that was being parsed.
  case usage(message: String, command: String)
  /// The arguments parse but a value is wrong.
  case invalid(message: String, command: String)

  package var code: ErrorCode {
    switch self {
    case .usage: .usage
    case .invalid: .invalid
    }
  }

  package var message: String {
    switch self {
    case .usage(let message, _), .invalid(let message, _): message
    }
  }

  package var next: [String] {
    switch self {
    case .usage(_, let command), .invalid(_, let command): ["\(command) --help"]
    }
  }
}
