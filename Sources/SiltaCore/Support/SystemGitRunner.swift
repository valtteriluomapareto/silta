import Darwin
package import Foundation

/// Executes an absolute git binary with isolated configuration and bounded direct-child lifetime.
package struct SystemGitRunner: GitRunner {
  private let executable: String
  private let killAfter: TimeInterval

  /// Defaults to Apple's absolute git path; no PATH search is performed.
  /// A timed-out child gets SIGTERM, then SIGKILL after `killAfter` seconds.
  package init(executable: String = "/usr/bin/git", killAfter: TimeInterval = 0.25) throws {
    guard executable.hasPrefix("/"), killAfter.isFinite, killAfter >= 0, killAfter <= 60 else {
      throw GitRunnerError.invalidConfiguration
    }
    self.executable = executable
    self.killAfter = killAfter
  }

  /// Waits on a dispatch worker, without blocking the caller's actor or cooperative executor.
  package func run(_ request: GitRequest) async throws -> GitResult {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do { continuation.resume(returning: try execute(request)) } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Capture files avoid pipe-buffer deadlocks and EOF
  /// waits on descriptors inherited by descendants. The runner reaps the direct child;
  /// it does not manage subprocess trees created by external git helpers.
  private func execute(_ request: GitRequest) throws -> GitResult {
    guard request.timeout.isFinite, request.timeout > 0, request.timeout <= 86_400 else {
      throw GitRunnerError.invalidConfiguration
    }
    let fm = FileManager.default
    let token = UUID()  // guard:allow-nondeterminism scratch identity
    let capture = fm.temporaryDirectory.appending(path: "silta-git-\(token.uuidString)")
    try fm.createDirectory(at: capture, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: capture) }  // best-effort cleanup after the child has exited
    let outURL = capture.appending(path: "stdout")
    let errURL = capture.appending(path: "stderr")
    guard fm.createFile(atPath: outURL.path, contents: nil),
      fm.createFile(atPath: errURL.path, contents: nil)
    else { throw GitRunnerError.captureCreationFailed }
    let stdout = try FileHandle(forWritingTo: outURL)
    defer { try? stdout.close() }  // best-effort close of an already captured stream
    let stderr = try FileHandle(forWritingTo: errURL)
    defer { try? stderr.close() }  // best-effort close of an already captured stream
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = request.arguments
    process.currentDirectoryURL = request.directory
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/empty",
      "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C",
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_SSH_COMMAND": "/usr/bin/ssh -o BatchMode=yes",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    let termination: GitTermination
    if exited.wait(timeout: .now() + request.timeout) == .timedOut {
      process.terminate()
      if exited.wait(timeout: .now() + killAfter) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        exited.wait()
      }
      termination = .timedOut
    } else {
      termination =
        process.terminationReason == .exit
        ? .exit(process.terminationStatus) : .signal(process.terminationStatus)
    }
    process.waitUntilExit()
    return try GitResult(
      termination: termination, stdout: Data(contentsOf: outURL), stderr: Data(contentsOf: errURL))
  }
}

private enum GitRunnerError: Error { case invalidConfiguration, captureCreationFailed }
