/// A human-only command refused for an agent actor.
package enum ActorError: CodedError {
  /// The caller supplies a body-free retry command with safely quoted identifiers.
  case humanOnly(command: String, actor: ActorID)

  /// An unblock of tasks that aren't ready, each named with what it waits on (an empty
  /// `on` is an answer), so the agent can tell the human why.
  case notReady(command: String, actor: ActorID, waits: [(ref: String, on: [String])])

  /// The supplied words are blank, too long or an unfilled placeholder.
  case invalidApproval

  /// Human intervention or corrected approval words are required.
  package var code: ErrorCode {
    switch self {
    case .humanOnly, .notReady: .humanOnly
    case .invalidApproval: .invalid
    }
  }

  /// Names the detected actor, and why an unknown agent was detected.
  package var message: String {
    switch self {
    case .humanOnly(_, let actor):
      return "This command needs the human's go-ahead; ask in chat. \(Self.detected(actor))"
    case .notReady(_, let actor, let waits):
      let each = waits.map {
        "\($0.ref) waits on \($0.on.isEmpty ? "an answer" : $0.on.joined(separator: ", "))"
      }
      let names =
        each.count < 2
        ? each.joined() : each.dropLast().joined(separator: ", ") + " and " + (each.last ?? "")
      return "\(names); unblocking needs the human's go-ahead, so ask in chat. "
        + Self.detected(actor)
    case .invalidApproval:
      return "--approved needs 1–300 Unicode scalars of the human's words, not a placeholder."
    }
  }

  /// The command to run after the human gives their go-ahead in chat.
  package var next: [String] {
    switch self {
    case .humanOnly(let command, _), .notReady(let command, _, _):
      [command + " --approved \"<the human's words>\""]
    case .invalidApproval: ["silta --help"]
    }
  }

  private static func detected(_ actor: ActorID) -> String {
    let reason =
      if case .agent("unknown", _) = actor { " (stdin or stdout is not a terminal)" } else { "" }
    return "Detected \(actor)\(reason)."
  }
}
