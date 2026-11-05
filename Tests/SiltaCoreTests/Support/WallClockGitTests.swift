import Darwin
import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

/// Wall-clock proof that a Git child ignoring SIGTERM is still killed at its deadline.
/// It runs only in the isolated deadline tier (`deadlineTestsEnabled()`), because a busy
/// machine can delay the child past a one-second deadline before it prints its marker.
@Suite(.tags(.deadline), .enabled(if: deadlineTestsEnabled()), .serialized, .timeLimit(.minutes(1)))
struct WallClockGitTests {
  @Test func timeoutKillsAChildIgnoringTermination() async throws {
    try await withScratchDirectory { scratch in
      let fifo = scratch.appending(path: "hold")
      try #require(mkfifo(fifo.path, 0o600) == 0)
      let script = scratch.appending(path: "git")
      // The marker confirms the handler was installed within the process deadline.
      // An ignored SIGTERM remains ignored across exec; cat blocks opening the FIFO.
      try Data("#!/bin/sh\ntrap '' TERM\nprintf ready\nexec /bin/cat \"$1\"\n".utf8).write(
        to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let result = try await SystemGitRunner(executable: script.path, killAfter: 0.01).run(
        GitRequest(arguments: [fifo.path], directory: scratch, timeout: 1))
      #expect(result.termination == .timedOut)
      #expect(result.stdout == Data("ready".utf8))
    }
  }
}
