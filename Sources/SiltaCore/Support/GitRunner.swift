package import Foundation

/// A git invocation. Arguments are passed directly, never through a shell.
package struct GitRequest: Equatable, Sendable {
  package let arguments: [String]
  package let directory: URL
  package let timeout: TimeInterval

  /// Uses a 10 s deadline, or 60 s for a leading `fetch` command. Flags before the
  /// verb require an explicit fetch deadline. The directory is not modified by the runner.
  package init(arguments: [String], directory: URL, timeout: TimeInterval? = nil) {
    self.arguments = arguments
    self.directory = directory
    self.timeout = timeout ?? (arguments.first == "fetch" ? 60 : 10)
  }
}

/// Distinguishes process failures from git's nonzero exit statuses.
package enum GitTermination: Equatable, Sendable {
  case exit(Int32)
  case signal(Int32)
  case timedOut
}

/// Lossless separate output streams, including on nonzero exit and timeout.
package struct GitResult: Equatable, Sendable {
  package let termination: GitTermination
  package let stdout: Data
  package let stderr: Data

  package init(termination: GitTermination, stdout: Data = Data(), stderr: Data = Data()) {
    self.termination = termination
    self.stdout = stdout
    self.stderr = stderr
  }
}

/// Runs git and returns its status and streams. Spawn and capture failures throw.
package protocol GitRunner: Sendable {
  func run(_ request: GitRequest) async throws -> GitResult
}
