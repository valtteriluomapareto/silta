package import Foundation

/// Command-log metadata. Command, actor, workspace, app, warning and error strings are
/// identifiers/codes only. Raw arguments, flag values, paths and bodies have no field here.
package struct LogEntry: Encodable, Equatable, Sendable {
  /// Command instant, supplied by the clock seam.
  package var timestamp: Date
  /// Command name; no raw arguments.
  package var command: String
  /// Actor identifier.
  package var actor: String
  /// Process exit status.
  package var exitCode: Int32
  /// Command duration in milliseconds.
  package var milliseconds: Int
  /// Workspace identifier, when known.
  package var workspace: String?
  /// App identifier, when known.
  package var app: String?
  /// Reported error table code, when the command failed.
  package var errorCode: ErrorCode?
  /// Flag names only; never flag values.
  package var flags: [String] = []
  /// Number of database busy retries.
  package var busyRetries: Int = 0
  /// Number of git invocations.
  package var gitCalls: Int = 0
  /// Total time in git, in milliseconds.
  package var gitMilliseconds: Int = 0
  /// Warning codes only; never message bodies.
  package var warnings: [String] = []

  /// Records the command name and safe identifiers, never command argument values.
  package init(timestamp: Date, command: String, actor: String, exitCode: Int32, milliseconds: Int)
  {
    self.timestamp = timestamp
    self.command = command
    self.actor = actor
    self.exitCode = exitCode
    self.milliseconds = milliseconds
  }
}
