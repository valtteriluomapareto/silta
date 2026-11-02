package import Foundation

/// How a `silta` child process ended.
package enum Termination: Equatable, Sendable {
  /// The process exited with this status.
  case exit(Int32)
  /// The process was killed by this signal, e.g. 11 for a crash.
  case signal(Int32)
}

/// What a `silta` run produced.
package struct CLIResult: Equatable, Sendable {
  /// How the process ended.
  package var termination: Termination
  /// Everything written to stdout, decoded as UTF-8.
  package var stdout: String
  /// Everything written to stderr, decoded as UTF-8.
  package var stderr: String

  /// A result to compare a run against.
  package init(termination: Termination, stdout: String, stderr: String) {
    self.termination = termination
    self.stdout = stdout
    self.stderr = stderr
  }
}

/// Why the built `silta` binary could not be run.
package struct SiltaBinaryError: Error, CustomStringConvertible {
  /// What went wrong, with the path that was tried.
  package var description: String
}

/// Runs the built `silta` executable as a black box, the way an agent's shell does.
package enum SiltaBinary {
  /// The `silta` executable in the build products directory, next to the test bundle.
  package static func url() throws -> URL {
    let products = Bundle(for: BundleAnchor.self).bundleURL
      .resolvingSymlinksInPath()
      .deletingLastPathComponent()
    let binary = products.appending(path: "silta", directoryHint: .notDirectory)
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      throw SiltaBinaryError(
        description: "no built silta at \(binary.path); run `swift build` first")
    }
    return binary
  }

  /// Runs `silta` with `arguments` in `scratch` and waits for it to finish.
  ///
  /// The child gets a fixed environment instead of inheriting this process's, so the
  /// developer's `SILTA_*`, `HOME` and git settings can't change the result:
  /// - `HOME` is `<scratch>/home`
  /// - `SILTA_HOME` is `<scratch>/silta-home`
  /// - `PATH` is the system default
  /// - `environment` is applied last and may override any of these
  ///
  /// stdout and stderr go to files in `scratch` rather than pipes, so large output
  /// can't block the child.
  package static func run(
    _ arguments: [String],
    in scratch: URL,
    environment: [String: String] = [:]
  ) throws -> CLIResult {
    let base = [
      "HOME": scratch.appending(path: "home").path,
      "SILTA_HOME": scratch.appending(path: "silta-home").path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    let stdoutURL = scratch.appending(path: "stdout")
    let stderrURL = scratch.appending(path: "stderr")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stdout.close()  // best-effort: the child has exited and the data is on disk
      try? stderr.close()  // best-effort: as above
    }

    let process = Process()
    process.executableURL = try url()
    process.arguments = arguments
    process.environment = base.merging(environment) { _, override in override }
    process.currentDirectoryURL = scratch
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let termination: Termination =
      switch process.terminationReason {
      case .exit: .exit(process.terminationStatus)
      case .uncaughtSignal: .signal(process.terminationStatus)
      @unknown default: .signal(process.terminationStatus)
      }
    return CLIResult(
      termination: termination,
      stdout: try utf8(contentsOf: stdoutURL),
      stderr: try utf8(contentsOf: stderrURL)
    )
  }

  /// Agent-facing output is UTF-8; anything else is a failure, not something to repair.
  private static func utf8(contentsOf url: URL) throws -> String {
    guard let text = String(bytes: try Data(contentsOf: url), encoding: .utf8) else {
      throw SiltaBinaryError(description: "\(url.lastPathComponent) is not valid UTF-8")
    }
    return text
  }
}

/// A class in this module, so `Bundle(for:)` finds the test bundle it is linked into.
private final class BundleAnchor {}
