import Foundation
import SiltaTestSupport
import Testing

struct SiltaBinaryTests {
  private func run(_ path: String, _ args: [String], timeout: Double = 30) throws -> CLIResult {
    try withScratchDirectory {
      try SiltaBinary.runProcess(URL(filePath: path), args, in: $0, timeout: timeout)
    }
  }

  @Test func scratchPathIsTheRealPathTheChildSees() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/pwd"), ["-P"], in: scratch, cwd: scratch)
      #expect(result == CLIResult(termination: .exit(0), stdout: scratch.path + "\n", stderr: ""))
    }
  }

  @Test func childEnvironmentIsTheAllowlistOnly() throws {
    let result = try run("/usr/bin/env", [])
    let names = Set(result.stdout.split(separator: "\n").map { String($0.prefix { $0 != "=" }) })
    // macOS adds __CF_USER_TEXT_ENCODING to every process it launches.
    #expect(names.subtracting(["__CF_USER_TEXT_ENCODING"]) == ["HOME", "PATH", "SILTA_HOME"])
  }

  @Test func captureFilesStayOutOfTheWorkingDirectory() throws {
    let result = try run("/bin/ls", ["-A"])
    #expect(result == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
  }

  @Test func signalIsNotAnExitCode() throws {
    let result = try run("/bin/sh", ["-c", "kill -ABRT $$"])
    #expect(result.termination == .signal(SIGABRT))
  }

  // These measure elapsed time because what they prove is that the runner stops
  // waiting: a runner that waited for the 30 s child would still report .timedOut.
  @Test func hungChildIsKilledAtTheTimeout() throws {
    var result: CLIResult?
    let elapsed = try ContinuousClock().measure {
      result = try run("/bin/sleep", ["30"], timeout: 0.5)
    }
    #expect(result?.termination == .timedOut)
    #expect(elapsed < .seconds(3))  // SIGTERM, not the SIGKILL fallback 5 s later
  }

  @Test func childIgnoringTermIsKilled() throws {
    var result: CLIResult?
    let elapsed = try ContinuousClock().measure {
      result = try withScratchDirectory {
        try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; exec /bin/sleep 30"], in: $0,
          timeout: 0.5, killAfter: 0.5)
      }
    }
    #expect(result?.termination == .timedOut)
    #expect(elapsed < .seconds(10))
  }
}
