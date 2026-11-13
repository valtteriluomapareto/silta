/// Retains a coded failure while applying the CLI's body-free recovery instructions.
package struct CommandFailure: WarnedFailure {
  /// Preserves the original error's scripting category.
  package let code: ErrorCode

  /// The original or caller-protected explanation, without retaining its error object.
  package let message: String

  /// Contains actual command paths and any safe workspace context.
  package let next: [String]

  /// Preserves the original bounded retry delay.
  package let retryAfter: Int?

  /// Preserves who acts on the original `next` commands.
  package let nextBy: NextBy

  /// Preserves the original failure's warnings.
  package let warnings: [OutputWarning]

  /// Captures public diagnostics and recovery; an omitted message preserves the original.
  package init(error: any CodedError, next: [String], nextBy: NextBy? = nil, message: String? = nil)
  {
    code = error.code
    self.message = message ?? error.message
    retryAfter = error.retryAfter
    self.nextBy = nextBy ?? error.nextBy
    warnings = (error as? any WarnedFailure)?.warnings ?? []
    self.next = next
  }
}
