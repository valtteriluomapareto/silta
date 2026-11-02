/// A human-only command refused for an agent actor.
package enum ActorError: CodedError {
  /// The retry skeleton is fixed by the command, never copied from user arguments.
  case humanOnly(command: StaticString)

  /// Human intervention is required.
  package var code: ErrorCode {
    .humanOnly
  }
  /// A one-line explanation independent of user content.
  package var message: String {
    "This command requires a human actor."
  }
  /// The command the human should run.
  package var next: [String] {
    switch self {
    case .humanOnly(let command): [String(describing: command)]
    }
  }
}
