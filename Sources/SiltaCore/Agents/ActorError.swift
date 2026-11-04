/// A human-only command refused for an agent actor.
package enum ActorError: CodedError {
  /// The caller supplies a body-free retry command with safely quoted identifiers.
  case humanOnly(command: String, actor: ActorID)

  /// A proposal policy gate names the task count and authorized status; an add title
  /// follows options and the approval placeholder.
  case proposalPolicy(command: String, actor: ActorID, title: String?, count: Int = 1)

  /// An unblock of tasks that aren't ready, each named with what it still waits on, so
  /// the agent can tell the human why.
  case notReady(command: String, actor: ActorID, waits: [Wait])

  /// A task that isn't ready: its unmet blockers, and its dropped blocker tasks. Both
  /// empty means it waits on an answer.
  package struct Wait: Sendable {
    let ref: String
    let open: [String]
    let dropped: [String]

    /// Names the task and what keeps it blocked.
    package init(ref: String, open: [String], dropped: [String]) {
      self.ref = ref
      self.open = open
      self.dropped = dropped
    }

    var text: String {
      let gone =
        dropped.isEmpty
        ? ""
        : "blocker\(dropped.count == 1 ? "" : "s") \(dropped.joined(separator: ", ")) dropped"
      if open.isEmpty {
        return gone.isEmpty ? "\(ref) waits on an answer" : "\(ref) has \(gone)"
      }
      return "\(ref) waits on \(open.joined(separator: ", "))" + (gone.isEmpty ? "" : " (\(gone))")
    }
  }

  /// The supplied words are blank, too long or an unfilled placeholder.
  case invalidApproval

  /// Human intervention or corrected approval words are required.
  package var code: ErrorCode {
    switch self {
    case .humanOnly, .notReady, .proposalPolicy: .humanOnly
    case .invalidApproval: .invalid
    }
  }

  /// Names the detected actor, and why an unknown agent was detected.
  package var message: String {
    switch self {
    case .humanOnly(_, let actor):
      return "This command needs the human's go-ahead; ask in chat. \(Self.detected(actor))"
    case .proposalPolicy(_, let actor, _, let count):
      return
        "This workspace sets proposals: ask; creating \(count == 1 ? "this task" : "these \(count) tasks") "
        + "needs the human's go-ahead in chat, and with it "
        + "\(count == 1 ? "the task is" : "the tasks are") created as todo. \(Self.detected(actor))"
    case .notReady(_, let actor, let waits):
      return waits.map(\.text).joined(separator: "; ")
        + "; unblocking needs the human's go-ahead, so ask in chat. "
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
    case .proposalPolicy(let command, _, let title, _):
      [
        command + " --approved \"<the human's words>\""
          + (title.map { " -- " + shellWord($0) } ?? "")
      ]
    case .invalidApproval: ["silta --help"]
    }
  }

  private static func detected(_ actor: ActorID) -> String {
    let reason =
      if case .agent("unknown", _) = actor { " (stdin or stdout is not a terminal)" } else { "" }
    return "Detected \(actor)\(reason)."
  }
}
