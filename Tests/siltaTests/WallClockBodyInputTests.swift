import Darwin
import Foundation
import SiltaTestSupport
import Testing

@Suite(
  .tags(.deadline), .enabled(if: deadlineTestsEnabled()), .serialized, .blockingTestWork,
  .timeLimit(.minutes(1)))
struct WallClockBodyInputTests {
  @Test func namedFifoRefusesWithoutWaitingForAWriter() throws {
    try withScratchDirectory { scratch in
      _ = try AcmeDocAttachments.make(in: scratch)
      let pipe = scratch.appending(path: "Acme input")
      try #require(mkfifo(pipe.path, 0o600) == 0)
      let result = try SiltaBinary.run(
        ["--ws", "acme", "doc", "edit", "rules"] + DocEditCommandTests.creation
          + ["-F", pipe.path, "--approved", "Keep these rules", "--json"],
        in: scratch, environment: TaskCommandTests.fixed, timeout: 5)
      withKnownIssue("#268: opening a named FIFO as a doc body waits for a writer") {
        #expect(result.termination == .exit(1))
        #expect(result.stdout.contains("\"code\":\"invalid\""))
        #expect(result.stderr.isEmpty)
      }
    }
  }

  @Test func oversizedStdinRefusesBeforeTheProducerCloses() throws {
    try withScratchDirectory { scratch in
      try BodyInputCommandTests.setupPlan(in: scratch)
      let file = scratch.appending(path: "body.md")
      try BodyInputCommandTests.oversizedPlan().write(to: file)
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/python3"),
        ["-c", Self.heldOpenInput, try SiltaBinary.url().path, file.path],
        in: scratch, environment: TaskCommandTests.actor, timeout: 10)
      withKnownIssue("#268: a supplied stdin body waits for EOF beyond the limit") {
        #expect(result.termination == .exit(1))
        #expect(result.stdout.contains("\"code\":\"invalid\""))
        #expect(result.stdout.contains("65536"))
        #expect(result.stderr.isEmpty)
      }
    }
  }

  private static let heldOpenInput = #"""
    import subprocess
    import sys

    binary, body = sys.argv[1:]
    child = subprocess.Popen(
        [binary, "--ws", "acme", "task", "plan", "AC-1", "-F", "-", "--json"],
        stdin=subprocess.PIPE, stdout=sys.stdout, stderr=sys.stderr,
    )
    try:
        with open(body, "rb") as source:
            child.stdin.write(source.read())
        child.stdin.flush()
        status = child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
        status = 124
    finally:
        child.stdin.close()
    sys.exit(status)
    """#
}
