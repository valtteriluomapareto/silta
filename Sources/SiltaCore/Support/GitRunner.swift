package import Foundation

/// A git invocation. Arguments are passed directly, never through a shell.
package struct GitRequest: Equatable, Sendable {
  /// Literal argument vector, including the git subcommand.
  package let arguments: [String]
  /// Working directory for the child process.
  package let directory: URL
  /// Seconds before termination is requested; must be finite and positive.
  package let timeout: TimeInterval
  /// Whether git may fetch missing promised objects. Suppression is best effort.
  package let lazyFetch: Bool

  /// Defaults to 10 s. Fetch callers pass 60 s explicitly (spec §10).
  package init(
    arguments: [String], directory: URL, timeout: TimeInterval = 10, lazyFetch: Bool = true
  ) {
    self.arguments = arguments
    self.directory = directory
    self.timeout = timeout
    self.lazyFetch = lazyFetch
  }
}

/// Distinguishes process failures from git's nonzero exit statuses.
package enum GitTermination: Equatable, Sendable {
  /// The child exited with this status.
  case exit(Int32)
  /// The child was killed by this signal.
  case signal(Int32)
  /// The deadline expired and the child was terminated.
  case timedOut
}

/// Lossless separate output streams, including on nonzero exit and timeout.
package struct GitResult: Equatable, Sendable {
  /// Exit status, signal, or deadline expiration.
  package let termination: GitTermination
  /// Bytes captured from standard output.
  package let stdout: Data
  /// Bytes captured from standard error.
  package let stderr: Data

  /// Creates a captured result without decoding or combining its streams.
  package init(termination: GitTermination, stdout: Data = Data(), stderr: Data = Data()) {
    self.termination = termination
    self.stdout = stdout
    self.stderr = stderr
  }
}

/// Runs git and returns its status and streams. Spawn and capture failures throw.
package protocol GitRunner: Sendable {
  /// Returns git status and streams; spawn/capture failures throw `SeamError`.
  /// System runners require finite, positive deadlines as a programmer precondition.
  func run(_ request: GitRequest) async throws -> GitResult
}
