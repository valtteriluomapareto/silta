/// Invalid discussion input or an unauthorized handoff.
package enum CommentError: CodedError {
  /// Input cannot be posted; the message contains no body content.
  case invalid(String)
  /// A concrete body-free retry for missing or blank content.
  case bodyRequired(String)
  /// Acceptance needs an answer; inspect the task discussion to choose it.
  case answerRequired(String)
  /// Another actor still holds the task being handed off.
  case foreignHandoff(String)

  /// A stored post was not found within its task.
  case missing(String, String)
  /// Deletion requires the post's author, not the task holder or a human override.
  case wrongAuthor(author: String, actor: String, root: String?, task: String)
  /// An optional explanation was empty; recovery never implies foreign-question consent.
  case explanationEmpty([String])

  /// A live thread must be reopened, or a deleted post cannot be used.
  case unavailable(String, task: String, reopen: String?)
  /// The asker or current task claimer can select an answer.
  case wrongAsker(asker: String, actor: String, task: String, root: String?)

  /// These invalid inputs have a concrete retry instead of generic command help.
  package var hasConcreteInvalidNext: Bool {
    switch self {
    case .bodyRequired, .explanationEmpty, .answerRequired: true
    default: false
    }
  }

  /// The existing invalid/conflict contract.
  package var code: ErrorCode {
    switch self {
    case .invalid, .bodyRequired, .explanationEmpty, .answerRequired: .invalid
    case .foreignHandoff, .wrongAuthor, .unavailable, .wrongAsker: .conflict
    case .missing: .notFound
    }
  }
  /// Names the refusal without echoing discussion content.
  package var message: String {
    switch self {
    case .invalid(let why): why
    case .unavailable(let why, _, _): why
    case .wrongAsker(let asker, let actor, _, _):
      "Only asker \(SecretGuard.redacted(asker)) or the current task claimer can accept an answer; current actor is \(SecretGuard.redacted(actor))."
    case .bodyRequired: "Comment body required; use -m or -F."
    case .answerRequired:
      "Accept requires a live answer ref; inspect the task discussion to choose one."
    case .missing(let ref, _): "Comment \(ref) not found."
    case .wrongAuthor(let author, let actor, _, _):
      "Only author \(SecretGuard.redacted(author)) can delete this comment; current actor is \(SecretGuard.redacted(actor))."
    case .explanationEmpty: "Explanation empty; follow the recovery guidance."
    case .foreignHandoff:
      "Only the current claimer can hand off this task; post ordinary discussion instead."
    }
  }
  /// An available read or posting command that recovers from the refusal.
  package var next: [String] {
    switch self {
    case .invalid: ["silta comment --help"]
    case .unavailable(_, let task, let root):
      root.map { ["silta comment reopen " + shellWord($0)] }
        ?? ["silta task show " + shellWord(task) + " --timeline"]
    case .wrongAsker(_, _, let task, _):
      ["silta task show " + shellWord(task) + " --timeline"]
    case .missing(_, let task):
      ["silta task show " + shellWord(task) + " --timeline"]
    case .wrongAuthor(_, _, _, let task):
      ["silta task show " + shellWord(task) + " --timeline"]
    case .answerRequired(let task): ["silta task show " + shellWord(task) + " --timeline"]
    case .explanationEmpty(let recovery): recovery
    case .bodyRequired(let command): [command + " -m \"<text>\""]
    case .foreignHandoff(let task): ["silta comment " + shellWord(task) + " --kind comment -F -"]
    }
  }
}
