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

  /// Optional bound for each captured stream. Other callers retain lossless capture.
  package let capture: GitCapture?

  /// Defaults to 10 s. Fetch callers pass 60 s explicitly (spec §10).
  package init(
    arguments: [String], directory: URL, timeout: TimeInterval = 10, lazyFetch: Bool = true,
    capture: GitCapture? = nil
  ) {
    self.arguments = arguments
    self.directory = directory
    self.timeout = timeout
    self.lazyFetch = lazyFetch
    self.capture = capture
  }
}

/// Bounds the retained bytes of each stream after skipping requested stdout lines.
package struct GitCapture: Equatable, Sendable {
  /// Per-stream byte limit. Must be positive and less than `Int.max`.
  package let byteLimit: Int
  /// Number of LF-delimited stdout lines to discard before capturing a prefix.
  package let skipLines: Int

  /// Returns a bounded capture request, optionally starting at a later stdout line.
  package init(byteLimit: Int, skipLines: Int = 0) {
    self.byteLimit = byteLimit
    self.skipLines = skipLines
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

/// Separate output streams, including on nonzero exit and timeout.
package struct GitResult: Equatable, Sendable {
  /// Exit status, signal, or deadline expiration.
  package let termination: GitTermination
  /// Bytes captured from standard output.
  package let stdout: Data
  /// Bytes captured from standard error.
  package let stderr: Data

  /// Whether stdout contains only a prefix of the requested window.
  package let stdoutTruncated: Bool
  /// Number of lines discarded before capture, at most the actual line count.
  package let stdoutSkippedLines: Int

  /// Creates a captured result without decoding or combining its streams.
  package init(
    termination: GitTermination, stdout: Data = Data(), stderr: Data = Data(),
    stdoutTruncated: Bool = false, stdoutSkippedLines: Int = 0
  ) {
    self.termination = termination
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.stdoutSkippedLines = stdoutSkippedLines
  }
}

/// Runs git and returns its status and streams. Spawn and capture failures throw.
package protocol GitRunner: Sendable {
  /// Returns git status and streams; spawn/capture failures throw `SeamError`.
  /// System runners require finite, positive deadlines as a programmer precondition.
  func run(_ request: GitRequest) async throws -> GitResult
}
