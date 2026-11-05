/// A failure that carries warnings, shown with its error in both output modes, for
/// what the caller should know even though the command failed.
package protocol WarnedFailure: CodedError {
  /// The warnings to show with the error.
  var warnings: [OutputWarning] { get }
}
