import SiltaTestSupport
import Testing

/// The CLI's output contract from the outside (spec §16, §20.1). Goldens were written
/// from the spec text.
struct OutputContractTests {
  private func silta(_ arguments: [String]) throws -> CLIResult {
    try withScratchDirectory { try SiltaBinary.run(arguments, in: $0) }
  }

  @Test func unknownFlagIsAUsageErrorOnStderr() throws {
    let result = try silta(["--nope"])
    #expect(result.termination == .exit(1))
    #expect(result.stdout.isEmpty)
    Golden.forTests().check(result.stderr, "usage-unknown-flag.txt")
  }

  @Test(arguments: [["--json", "--nope"], ["--nope", "--json"]])
  func unknownFlagWithJSONIsAnEnvelopeOnStdout(arguments: [String]) throws {
    let result = try silta(arguments)
    #expect(result.termination == .exit(1))
    #expect(result.stderr.isEmpty)
    Golden.forTests().check(result.stdout, "usage-unknown-flag.json")
  }

  @Test func unexpectedArgumentIsAUsageError() throws {
    let result = try silta(["frobnicate", "--json"])
    #expect(result.termination == .exit(1))
    #expect(result.stderr.isEmpty)
    Golden.forTests().check(result.stdout, "usage-unexpected-argument.json")
  }

  @Test(arguments: [["--help"], ["--help", "--json"], ["--json", "--help"]])
  func helpIsPlainTextOnStdout(arguments: [String]) throws {
    let result = try silta(arguments)
    #expect(result.termination == .exit(0))
    #expect(result.stdout.hasPrefix("OVERVIEW: "))
    #expect(result.stderr.isEmpty)
  }

  @Test(arguments: [["--version", "--json"], ["--json", "--version"]])
  func versionIgnoresJSON(arguments: [String]) throws {
    let result = try silta(arguments)
    #expect(result.termination == .exit(0))
    #expect(result.stdout.wholeMatch(of: /\d+\.\d+\.\d+\n/) != nil)
    #expect(result.stderr.isEmpty)
  }

  // `--json` after `--` is an argument, not the flag.
  @Test func jsonAfterDoubleDashIsNotTheFlag() throws {
    let result = try silta(["--", "--json"])
    #expect(result.termination == .exit(1))
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.hasPrefix("error: "))
  }
}
