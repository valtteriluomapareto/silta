/// Invalid discussion input or an unauthorized handoff.
package enum CommentError: CodedError {
  /// Input cannot be posted; the message contains no body content.
  case invalid(String)
  /// A concrete body-free retry for missing or blank content.
  case bodyRequired(String)
  /// Another actor still holds the task being handed off.
  case foreignHandoff(String)

  /// The existing invalid/conflict contract.
  package var code: ErrorCode {
    switch self {
    case .invalid, .bodyRequired: .invalid
    case .foreignHandoff: .conflict
    }
  }
  /// Names the refusal without echoing discussion content.
  package var message: String {
    switch self {
    case .invalid(let why): why
    case .bodyRequired: "Comment body required; use -m or -F."
    case .foreignHandoff:
      "Only the current claimer can hand off this task; post ordinary discussion instead."
    }
  }
  /// An available read or posting command that recovers from the refusal.
  package var next: [String] {
    switch self {
    case .invalid: ["silta comment --help"]
    case .bodyRequired(let command): [command + " -m \"<text>\""]
    case .foreignHandoff(let task): ["silta comment " + shellWord(task) + " --kind comment -F -"]
    }
  }
}
