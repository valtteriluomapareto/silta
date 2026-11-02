import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
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
    #expect(result.termination != .exit(0))
    #expect(result.stdout.isEmpty)
    #expect(!result.stderr.isEmpty)
  }
}
