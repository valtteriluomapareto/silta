/// Code reads fail without exposing raw git diagnostics or credentials.
package enum CodeError: CodedError {
  /// A caller supplied an unsupported selection or argument.
  case invalid(String, command: String)
  /// An app, ref or path could not be found, with recovery commands.
  case notFound(String, next: [String])
  /// Git failed, or its output could not be read.
  case git(repo: String, workspace: String)
  /// Git exceeded its deadline; `command` is the read's command path.
  case timeout(command: String)
  /// `--fetch` failed; `retry` repeats the read without it.
  case fetch(repo: String, retry: String)

  /// Maps reads to the existing scripting error codes.
  package var code: ErrorCode {
    switch self {
    case .invalid: .invalid
    case .notFound: .notFound
    case .git, .timeout, .fetch: .env
    }
  }

  /// Describes the selection or environment needing repair.
  package var message: String {
    switch self {
    case .invalid(let message, _), .notFound(let message, _): message
    case .git(let repo, _):
      "Could not read code in \(repo.debugDescription); check the local clone and git environment."
    case .timeout: "Git took longer than 10 s; narrow the read and retry."
    case .fetch(let repo, _):
      "Could not fetch \(repo.debugDescription); check network access and noninteractive git "
        + "credentials, or read the cached ref without --fetch."
    }
  }

  /// Supplies body-free discovery, retry or help commands.
  package var next: [String] {
    switch self {
    case .invalid(_, let command), .timeout(let command): [command + " --help"]
    case .notFound(_, let next): next
    case .git(let repo, let workspace):
      ["silta --ws \(shellWord(workspace)) repo fetch \(shellWord(repo))"]
    case .fetch(_, let retry): [retry]
    }
  }

  /// Narrowing a read or reading the cached ref is the agent's next step.
  package var nextBy: NextBy {
    switch self {
    case .timeout, .fetch: .agent
    default: code.nextBy
    }
  }
}
