import Darwin
package import Foundation

/// How a child process ended.
package enum Termination: Equatable, Sendable {
  /// The process exited with this status.
  case exit(Int32)
  /// The process was killed by this signal, e.g. 6 for an abort.
  case signal(Int32)
  /// The process outlived its timeout and was killed.
  case timedOut
}

/// What a child process produced.
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

/// Why a child process could not be run.
package struct SiltaBinaryError: Error, CustomStringConvertible {
  /// What went wrong, with the path that was tried.
  package var description: String
}

/// Runs the built `silta` executable as a black box, the way an agent's shell does.
///
/// A scratch directory is laid out as:
/// - `home/`: the child's `HOME`
/// - `silta-home/`: the child's `SILTA_HOME`
/// - `work/`: the default working directory
/// - `runs/<id>/`: captured stdout and stderr, one directory per run, so concurrent
///   runs never share files and nothing appears in the child's working directory
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

  /// Runs `silta` with `arguments` and waits for it to finish.
  ///
  /// The child gets a fixed environment instead of inheriting this process's, so the
  /// developer's `SILTA_*`, `HOME` and git settings can't change the result: `HOME`,
  /// `SILTA_HOME` and a default `PATH`, then `environment` on top.
  ///
  /// - Parameters:
  ///   - scratch: a directory from `withScratchDirectory`.
  ///   - cwd: the working directory; `<scratch>/work` when nil.
  ///   - timeout: seconds before the child is terminated and the result is `.timedOut`.
  package static func run(
    _ arguments: [String],
    in scratch: URL,
    cwd: URL? = nil,
    environment: [String: String] = [:],
    timeout: Double = 30
  ) throws -> CLIResult {
    try runProcess(
      try url(), arguments, in: scratch, cwd: cwd, environment: environment, timeout: timeout)
  }

  /// Runs any executable under the same rules as `run`. Used to test the runner itself.
  package static func runProcess(
    _ executable: URL,
    _ arguments: [String],
    in scratch: URL,
    cwd: URL? = nil,
    environment: [String: String] = [:],
    timeout: Double = 30
  ) throws -> CLIResult {
    let fm = FileManager.default
    let home = scratch.appending(path: "home", directoryHint: .isDirectory)
    let siltaHome = scratch.appending(path: "silta-home", directoryHint: .isDirectory)
    let work = cwd ?? scratch.appending(path: "work", directoryHint: .isDirectory)
    let capture = scratch.appending(path: "runs/\(UUID().uuidString)", directoryHint: .isDirectory)
    for directory in [home, work, capture] {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let stdoutURL = capture.appending(path: "stdout")
    let stderrURL = capture.appending(path: "stderr")
    fm.createFile(atPath: stdoutURL.path, contents: nil)
    fm.createFile(atPath: stderrURL.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stdout.close()  // best-effort: the child has exited and the data is on disk
      try? stderr.close()  // best-effort: as above
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = [
      "HOME": home.path,
      "SILTA_HOME": siltaHome.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ].merging(environment) { _, override in override }
    process.currentDirectoryURL = work
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    return CLIResult(
      termination: try runToEnd(process, timeout: timeout),
      stdout: try utf8(contentsOf: stdoutURL),
      stderr: try utf8(contentsOf: stderrURL)
    )
  }

  /// Starts `process` and waits for it, killing it if it outlives `timeout` seconds.
  /// The deadline bounds a hung child; it never stands in for waiting on a result.
  private static func runToEnd(_ process: Process, timeout: Double) throws -> Termination {
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if exited.wait(timeout: .now() + 5) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        exited.wait()
      }
      process.waitUntilExit()
      return .timedOut
    }
    process.waitUntilExit()
    switch process.terminationReason {
    case .exit: return .exit(process.terminationStatus)
    case .uncaughtSignal: return .signal(process.terminationStatus)
    @unknown default: return .signal(process.terminationStatus)
    }
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
