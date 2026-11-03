/// A busy storage failure with the body-free command path supplied by the CLI.
package struct CommandBusyError: CodedError {
  /// Retains the retryable busy contract.
  package var code: ErrorCode { .busy }

  /// Explains the bounded retry policy.
  package var message: String { StorageError.busy.message }

  /// The actual parsed command, without arguments that can contain bodies.
  package let next: [String]

  /// The bounded wait before one caller retry.
  package var retryAfter: Int? { StorageError.busy.retryAfter }

  /// The caller supplies only names from its parsed command tree.
  package init(command: String) {
    next = [command]
  }
}
