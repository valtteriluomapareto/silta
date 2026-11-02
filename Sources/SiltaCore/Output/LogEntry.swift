package import Foundation

/// Command-log metadata. Command, actor, workspace, app, warning and error strings are
/// identifiers/codes only. Raw arguments, flag values, paths and bodies have no field here.
package struct LogEntry: Codable, Equatable, Sendable {
  package var timestamp: Date
  package var command: String
  package var actor: String
  package var exitCode: Int32
  package var milliseconds: Int
  package var workspace: String?
  package var app: String?
  package var errorCode: String?
  package var flags: [String] = []
  package var busyRetries: Int = 0
  package var gitCalls: Int = 0
  package var gitMilliseconds: Int = 0
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
