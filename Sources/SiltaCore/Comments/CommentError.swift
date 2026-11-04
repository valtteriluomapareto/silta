/// Invalid discussion input or an unauthorized handoff.
package enum CommentError: CodedError {
  /// Input cannot be posted; the message contains no body content.
  case invalid(String)
  /// A concrete body-free retry for missing or blank content.
  case bodyRequired(String)
  /// Another actor still holds the task being handed off.
  case foreignHandoff(String)

  /// A stored post was not found within its task.
  case missing(String, String)
  /// A discussion permission or state refusal with task recovery.
  case conflict(String, String)

  /// The existing invalid/conflict contract.
  package var code: ErrorCode {
    switch self {
    case .invalid, .bodyRequired: .invalid
    case .foreignHandoff, .conflict: .conflict
    case .missing: .notFound
    }
  }
  /// Names the refusal without echoing discussion content.
  package var message: String {
    switch self {
    case .invalid(let why): why
    case .bodyRequired: "Comment body required; use -m or -F."
    case .missing(let ref, _): "Comment \(ref) not found."
    case .conflict(let why, _): why
    case .foreignHandoff:
      "Only the current claimer can hand off this task; post ordinary discussion instead."
    }
  }
  /// An available read or posting command that recovers from the refusal.
  package var next: [String] {
    switch self {
    case .invalid: ["silta comment --help"]
    case .missing(_, let task), .conflict(_, let task):
      ["silta task show " + shellWord(task) + " --timeline"]
    case .bodyRequired(let command): [command + " -m \"<text>\""]
    case .foreignHandoff(let task): ["silta comment " + shellWord(task) + " --kind comment -F -"]
    }
  }
}
