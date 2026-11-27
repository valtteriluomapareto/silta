import Darwin
package import Foundation

/// Executes an absolute git binary with noninteractive authentication and a bounded
/// direct-child lifetime.
package struct SystemGitRunner: GitRunner {
  private let executable: String
  private let environment: [String: String]
  private let killAfter: TimeInterval

  /// Defaults to Apple's absolute git path; no PATH search is performed.
  /// A timed-out child gets SIGTERM, then SIGKILL after `killAfter` seconds.
  /// Inherits the supplied environment except ambient GIT_* overrides.
  /// Git reads the user's configuration and credentials. The fixed GIT_SSH_COMMAND
  /// overrides core.sshCommand to disable interactive SSH authentication.
  package init(
    executable: String = "/usr/bin/git", killAfter: TimeInterval = 0.25,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    precondition(
      killAfter.isFinite && killAfter > 0, "Git termination grace must be finite and positive")
    self.executable = executable
    self.killAfter = killAfter
    var child = environment.filter { !$0.key.hasPrefix("GIT_") }
    child.merge([
      "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
      "LC_ALL": "C",
      "GIT_SSH_COMMAND": "/usr/bin/ssh -o BatchMode=yes",
    ]) { _, fixed in fixed }
    self.environment = child
  }

  /// Waits on a dispatch worker, without blocking the caller's actor or cooperative executor.
  package func run(_ request: GitRequest) async throws -> GitResult {
    // Process raises an uncatchable exception for a missing or non-file directory. A
    // working directory deleted under the shell reads as "", which becomes `./`.
    let path = request.directory.path
    var isDirectory: ObjCBool = false
    guard request.directory.isFileURL, path.hasPrefix("/"),
      FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw SeamError.gitUnavailable }
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          continuation.resume(returning: try execute(request))
        } catch let error as SeamError {
          continuation.resume(throwing: error)
        } catch {
          continuation.resume(throwing: SeamError.gitCapture)
        }
      }
    }
  }

  /// Capture files avoid pipe-buffer deadlocks and EOF
  /// waits on descriptors inherited by descendants. The runner reaps the direct child;
  /// it does not manage subprocess trees created by external git helpers.
  private func execute(_ request: GitRequest) throws -> GitResult {
    precondition(
      request.timeout.isFinite && request.timeout > 0, "Git timeout must be finite and positive")
    guard executable.hasPrefix("/") else { throw SeamError.gitUnavailable }
    let fm = FileManager.default
    let token = UUID()  // guard:allow-nondeterminism scratch identity
    let capture = fm.temporaryDirectory.appending(path: "silta-git-\(token.uuidString)")
    try fm.createDirectory(at: capture, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: capture) }  // best-effort cleanup after the child has exited
    let outURL = capture.appending(path: "stdout")
    let errURL = capture.appending(path: "stderr")
    guard fm.createFile(atPath: outURL.path, contents: nil),
      fm.createFile(atPath: errURL.path, contents: nil)
    else { throw SeamError.gitCapture }
    let stdout = try FileHandle(forWritingTo: outURL)
    defer { try? stdout.close() }  // best-effort close of an already captured stream
    let stderr = try FileHandle(forWritingTo: errURL)
    defer { try? stderr.close() }  // best-effort close of an already captured stream
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = request.arguments
    process.currentDirectoryURL = request.directory
    var childEnvironment = environment
    if !request.lazyFetch {
      childEnvironment["GIT_NO_LAZY_FETCH"] = "1"
      childEnvironment["GIT_ALLOW_PROTOCOL"] = ""
    }
    process.environment = childEnvironment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      throw SeamError.gitUnavailable
    }
    let deadline = DispatchTime.now() + request.timeout
    let termination = waitForChild(process, exited: exited, deadline: deadline)
    return try readCapture(
      termination, from: outURL, errors: errURL, limit: request.capture, deadline: deadline)
  }

  private func waitForChild(
    _ process: Process, exited: DispatchSemaphore, deadline: DispatchTime
  ) -> GitTermination {
    if exited.wait(timeout: deadline) == .timedOut {
      process.terminate()
      if exited.wait(timeout: .now() + killAfter) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        exited.wait()
      }
      process.waitUntilExit()
      return .timedOut
    }
    process.waitUntilExit()
    return process.terminationReason == .exit
      ? .exit(process.terminationStatus) : .signal(process.terminationStatus)
  }

  private func readCapture(
    _ termination: GitTermination, from stdout: URL, errors stderr: URL, limit: GitCapture?,
    deadline: DispatchTime
  ) throws -> GitResult {
    guard let limit else {
      return try GitResult(
        termination: termination, stdout: Data(contentsOf: stdout), stderr: Data(contentsOf: stderr)
      )
    }
    let out = try FileHandle(forReadingFrom: stdout)
    defer { try? out.close() }  // best-effort close of an already captured stream
    let err = try FileHandle(forReadingFrom: stderr)
    defer { try? err.close() }  // best-effort close of an already captured stream
    // Inherited stdout can still grow after the direct child exits.
    let end = try out.seekToEnd()
    try out.seek(toOffset: 0)
    let skipped =
      termination == .timedOut ? 0 : try skipLines(limit.skipLines, in: out, end: end) ?? 0
    let available = end - (try out.offset())
    let kept = Int(min(available, UInt64(limit.byteLimit)))
    let bytes = kept == 0 ? Data() : try out.read(upToCount: kept) ?? Data()
    let truncated = available > UInt64(limit.byteLimit)
    var count: Int?
    if truncated, limit.countLines, termination == .exit(0) {
      try out.seek(toOffset: 0)
      count = try skipLines(Int.max, in: out, end: end, deadline: deadline)
    }
    return try GitResult(
      termination: termination, stdout: bytes,
      stderr: err.read(upToCount: limit.byteLimit) ?? Data(),
      stdoutTruncated: truncated, stdoutSkippedLines: skipped, stdoutLineCount: count)
  }

  /// Seek to a later line using fixed-size blocks, including across an oversized line.
  /// If the requested line is beyond EOF, report the actual number of preceding lines.
  private func skipLines(
    _ count: Int, in file: FileHandle, end: UInt64, deadline: DispatchTime = .distantFuture
  ) throws -> Int? {
    guard count > 0 else { return 0 }
    var offset: UInt64 = 0
    var skipped = 0
    var unterminated = false
    while offset < end,
      let chunk = try file.read(upToCount: Int(min(end - offset, 32 * 1024))), !chunk.isEmpty
    {
      guard DispatchTime.now() < deadline else { return nil }
      var start = chunk.startIndex
      while let newline = chunk[start...].firstIndex(of: 10) {
        skipped += 1
        start = newline + 1
        if skipped == count {
          try file.seek(toOffset: offset + UInt64(start))
          return skipped
        }
      }
      unterminated = start < chunk.endIndex
      offset += UInt64(chunk.count)
    }
    return skipped + (unterminated ? 1 : 0)
  }
}
