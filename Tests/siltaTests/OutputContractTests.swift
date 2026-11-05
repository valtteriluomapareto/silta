import SiltaTestSupport
import Testing

/// The CLI's output contract from the outside (spec §16, §20.1). Goldens were written
/// from the spec text.
@Suite(.blockingTestWork)
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

  // Spec §16: bare `silta` prints the status line; without storage, its fallback.
  @Test(arguments: [
    ([String](), "No workspace here; next: silta ws ls\n"),
    (
      ["--json"],
      "{\"data\":{\"location\":\"unregistered\"},\"ok\":true,\"schema\":1,\"warnings\":[]}\n"
    ),
  ])
  func bareSiltaPrintsTheStatusLine(arguments: [String], stdout: String) throws {
    let result = try silta(arguments)
    #expect(result == CLIResult(termination: .exit(0), stdout: stdout, stderr: ""))
  }

  // Arguments can carry bodies, so a parse error never repeats one at length.
  @Test func longArgumentIsCappedInTheMessage() throws {
    let result = try silta(["--json", String(repeating: "x", count: 3000) + "\nline two"])
    #expect(result.termination == .exit(1))
    let message = try #require(result.stdout.firstMatch(of: /"message":"([^"]*)"/)?.output.1)
    #expect(message.count <= 200)
    #expect(!message.contains("line two"))
  }

  // `--json` after `--` is an argument, not the flag.
  @Test func jsonAfterDoubleDashIsNotTheFlag() throws {
    let result = try silta(["--", "--json"])
    #expect(result.termination == .exit(1))
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.hasPrefix("error: "))
  }
}
