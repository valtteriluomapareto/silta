/// A human-only command refused for an agent actor.
package enum ActorError: CodedError {
  /// The caller supplies a body-free retry command with safely quoted identifiers.
  case humanOnly(command: String, actor: ActorID)

  /// The supplied words are blank, too long or an unfilled placeholder.
  case invalidApproval

  /// Human intervention or corrected approval words are required.
  package var code: ErrorCode {
    switch self {
    case .humanOnly: .humanOnly
    case .invalidApproval: .invalid
    }
  }

  /// Names the detected actor, and why an unknown agent was detected.
  package var message: String {
    switch self {
    case .humanOnly(_, let actor):
      let reason =
        if case .agent("unknown", _) = actor { " (stdin or stdout is not a terminal)" } else { "" }
      return "This command needs the human's go-ahead; ask in chat. Detected \(actor)\(reason)."
    case .invalidApproval:
      return "--approved needs 1–300 Unicode scalars of the human's words, not a placeholder."
    }
  }

  /// The command to run after the human gives their go-ahead in chat.
  package var next: [String] {
    switch self {
    case .humanOnly(let command, _): [command + " --approved \"<the human's words>\""]
    case .invalidApproval: ["silta --help"]
    }
  }
}
