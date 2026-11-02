import Darwin

/// Terminal status captured once at the command boundary.
package struct TerminalState: Sendable {
  /// Whether standard input is a terminal.
  package let stdinIsTTY: Bool
  /// Whether standard output is a terminal.
  package let stdoutIsTTY: Bool

  /// Supplies a terminal snapshot without reading process state.
  package init(stdin: Bool, stdout: Bool) {
    stdinIsTTY = stdin
    stdoutIsTTY = stdout
  }

  /// Reads the two process descriptors used by actor detection.
  package static func system() -> TerminalState {
    TerminalState(stdin: isatty(STDIN_FILENO) != 0, stdout: isatty(STDOUT_FILENO) != 0)
  }
}
