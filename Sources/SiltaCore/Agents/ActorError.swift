/// A human-only command refused for an agent actor.
package enum ActorError: CodedError {
  /// The caller supplies a body-free retry command with safely quoted identifiers.
  case humanOnly(command: String, actor: ActorID)

  /// Human intervention is required.
  package var code: ErrorCode {
    .humanOnly
  }

  /// Names the detected actor, and why an unknown agent was detected.
  package var message: String {
    switch self {
    case .humanOnly(_, let actor):
      let reason =
        if case .agent("unknown", _) = actor { " (stdin or stdout is not a terminal)" } else { "" }
      return "This command requires a human actor; detected \(actor)\(reason)."
    }
  }

  /// The command the human should run.
  package var next: [String] {
    switch self {
    case .humanOnly(let command, _): [command]
    }
  }
}
