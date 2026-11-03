/// Retains a coded failure while applying the CLI's body-free recovery instructions.
package struct CommandFailure: CodedError {
  /// Preserves the original error's scripting category.
  package let code: ErrorCode

  /// Preserves the original explanation without retaining its error object.
  package let message: String

  /// Contains actual command paths and any safe workspace context.
  package let next: [String]

  /// Preserves the original bounded retry delay.
  package let retryAfter: Int?

  /// Captures only public diagnostics and the corrected recovery commands.
  package init(error: any CodedError, next: [String]) {
    code = error.code
    message = error.message
    retryAfter = error.retryAfter
    self.next = next
  }
}
