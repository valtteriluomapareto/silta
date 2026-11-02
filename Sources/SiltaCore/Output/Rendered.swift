/// The exact bytes a command writes and the status it exits with.
package struct Rendered: Equatable, Sendable {
  /// Everything for stdout.
  package var stdout: String
  /// Everything for stderr.
  package var stderr: String
  /// The process exit status.
  package var exitCode: Int32
  /// The error code, when the command failed.
  package var errorCode: ErrorCode?

  /// A rendering with both streams, the exit status and the error code.
  package init(stdout: String, stderr: String, exitCode: Int32, errorCode: ErrorCode?) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
    self.errorCode = errorCode
  }
}
