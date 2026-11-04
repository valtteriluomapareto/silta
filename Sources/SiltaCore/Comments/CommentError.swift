/// Invalid discussion input or an unauthorized handoff.
package enum CommentError: CodedError {
  /// Input cannot be posted; the message contains no body content.
  case invalid(String)
  /// Another actor still holds the task being handed off.
  case foreignHandoff(String)

  /// The existing invalid/conflict contract.
  package var code: ErrorCode {
    switch self {
    case .invalid: .invalid
    case .foreignHandoff: .conflict
    }
  }
  /// Names the refusal without echoing discussion content.
  package var message: String {
    switch self {
    case .invalid(let why): why
    case .foreignHandoff:
      "Only the current claimer can hand off this task; post ordinary discussion instead."
    }
  }
  /// An available read or posting command that recovers from the refusal.
  package var next: [String] {
    switch self {
    case .invalid: ["silta comment --help"]
    case .foreignHandoff(let task): ["silta comment " + shellWord(task) + " --kind comment -F -"]
    }
  }
}
