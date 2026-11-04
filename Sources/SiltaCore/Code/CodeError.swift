/// Code reads fail without exposing raw git diagnostics or credentials.
package enum CodeError: CodedError {
  /// A caller supplied an unsupported selection or argument.
  case invalid(String, command: String)
  /// An app, ref or path could not be found, with recovery commands.
  case notFound(String, next: [String])
  /// Git failed or exceeded its deadline.
  case git(repo: String, workspace: String)

  /// Maps reads to the existing scripting error codes.
  package var code: ErrorCode {
    switch self {
    case .invalid: .invalid
    case .notFound: .notFound
    case .git: .env
    }
  }

  /// Describes the selection or environment needing repair.
  package var message: String {
    switch self {
    case .invalid(let message, _), .notFound(let message, _): message
    case .git(let repo, _):
      "Could not read code in \(repo.debugDescription); check the local clone and git environment."
    }
  }

  /// Supplies body-free discovery, retry or help commands.
  package var next: [String] {
    switch self {
    case .invalid(_, let command): [command + " --help"]
    case .notFound(_, let next): next
    case .git(let repo, let workspace):
      ["silta --ws \(shellWord(workspace)) repo fetch \(shellWord(repo))"]
    }
  }
}
