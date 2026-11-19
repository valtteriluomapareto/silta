import ArgumentParser
import Darwin
import Foundation
import SiltaCore

/// Starts the user's configured shell command with a terminal separate from CLI output.
enum TerminalEditor {
  static func validate() throws {
    guard isatty(STDIN_FILENO) != 0, isatty(STDERR_FILENO) != 0 else {
      throw ValidationError(
        "Editing needs terminal input and terminal stderr. Supply -F <file> or -F - for stdin.")
    }
  }

  static func run(_ file: URL, command: String) throws -> Int32 {
    let configured = ProcessInfo.processInfo.environment["EDITOR"] ?? ""
    let editor = configured.isEmpty ? "vi" : configured
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    // The file path is a positional argument to the user's shell command.
    process.arguments = ["-c", "exec " + editor + " \"$1\"", "silta-editor", file.path]
    process.standardOutput = FileHandle.standardError
    process.standardError = FileHandle.standardError
    let failure = CommandFailure(error: WorkspaceError.editor, next: [command + " --help"])
    do {
      try process.run()
    } catch { throw failure }
    process.waitUntilExit()
    // The shell reserves these statuses for a command it could not execute.
    guard process.terminationReason != .exit || ![126, 127].contains(process.terminationStatus)
    else { throw failure }
    return process.terminationStatus
  }
}
