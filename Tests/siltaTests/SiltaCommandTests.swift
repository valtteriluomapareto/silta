import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct SiltaCommandTests {
  @Test func versionPrintsTheVersionConstant() throws {
    let result = try withScratchDirectory { try SiltaBinary.run(["--version"], in: $0) }
    #expect(
      result == CLIResult(termination: .exit(0), stdout: SiltaVersion.current + "\n", stderr: ""))
  }

  // Exact exit and error codes belong to the output contract (spec §16); this only pins
  // that an error never writes to stdout (spec §20.1).
  @Test func unknownFlagFailsWithNothingOnStdout() throws {
    let result = try withScratchDirectory { try SiltaBinary.run(["--no-such-flag"], in: $0) }
    if case .exit(let code) = result.termination {
      #expect(code != 0)
    } else {
      Issue.record("expected an exit, got \(result.termination)")
    }
    #expect(result.stdout.isEmpty)
    #expect(!result.stderr.isEmpty)
  }
}
