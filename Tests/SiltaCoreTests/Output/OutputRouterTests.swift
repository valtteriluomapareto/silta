import SiltaCore
import Testing

struct OutputRouterTests {
  struct Sample: CodedError {
    var code: ErrorCode
    var message = "it broke ä"
    var next = ["silta fix --now"]
    var retryAfter: Int?
  }

  struct Payload: Encodable, Sendable {
    var name = "ä/b"
    var count = 2
  }

  private let text = OutputMode(json: false, quiet: false)
  private let json = OutputMode(json: true, quiet: false)

  @Test(arguments: ErrorCode.allCases, [false, true])
  func codedErrorInTextModeGoesToStderr(code: ErrorCode, quiet: Bool) {
    let rendered = OutputRouter.render(
      .failure(Sample(code: code)), mode: OutputMode(json: false, quiet: quiet))
    let verb = code.nextBy == .human ? "ask human" : "next"
    #expect(
      rendered
        == Rendered(
          stdout: "",
          stderr: "error: it broke ä [\(code.rawValue)]\n\(verb): silta fix --now\n",
          exitCode: code.exitCode, errorCode: code))
  }

  @Test(arguments: ErrorCode.allCases, [false, true])
  func codedErrorInJSONModeGoesToStdout(code: ErrorCode, quiet: Bool) {
    let rendered = OutputRouter.render(
      .failure(Sample(code: code)), mode: OutputMode(json: true, quiet: quiet))
    let expected =
      #"{"error":{"code":"\#(code.rawValue)","message":"it broke ä","next":["silta fix --now"],"#
      + #""next_by":"\#(code.nextBy.rawValue)"},"ok":false,"schema":1,"warnings":[]}"# + "\n"
    #expect(
      rendered == Rendered(stdout: expected, stderr: "", exitCode: code.exitCode, errorCode: code))
  }

  @Test func retryAfterIsShownWhenSet() {
    let error = Sample(code: .rateLimited, next: ["silta comment AC-1 -F -"], retryAfter: 240)
    #expect(
      OutputRouter.render(.failure(error), mode: text).stderr
        == "error: it broke ä [rate_limited]\nretry after: 240s\nnext: silta comment AC-1 -F -\n")
    #expect(
      OutputRouter.render(.failure(error), mode: json).stdout
        == #"{"error":{"code":"rate_limited","message":"it broke ä","#
        + #""next":["silta comment AC-1 -F -"],"next_by":"agent","retry_after_s":240},"#
        + #""ok":false,"schema":1,"warnings":[]}"# + "\n")
  }

  @Test func severalNextCommandsAreAllShown() {
    let error = Sample(
      code: .humanOnly, next: ["silta task done AC-1 --force", "silta task show AC-1"])
    #expect(
      OutputRouter.render(.failure(error), mode: text).stderr
        == "error: it broke ä [human_only]\nask human: silta task done AC-1 --force\n"
        + "ask human: silta task show AC-1\n")
    #expect(
      OutputRouter.render(.failure(error), mode: json).stdout.contains(
        #""next":["silta task done AC-1 --force","silta task show AC-1"],"next_by":"human""#))
  }

  struct Unencodable: Encodable, Sendable {
    var value = Double.nan
  }

  @Test(arguments: [false, true])
  func dataThatCannotBeEncodedIsAnInternalError(json: Bool) {
    let output = CommandOutput(text: "done", data: Unencodable())
    let rendered = OutputRouter.render(.success(output), mode: OutputMode(json: json))
    #expect(rendered.exitCode == (json ? 9 : 0))
    #expect(rendered.errorCode == (json ? .env : nil))
    if json {
      #expect(rendered.stdout.hasPrefix(#"{"error":{"code":"env""#))
      #expect(rendered.stderr.isEmpty)
    }
  }

  @Test func successInTextMode() {
    let output = CommandOutput(
      text: "done", data: Payload(),
      warnings: [OutputWarning(code: "ref_stale", message: "origin/x is behind")])
    #expect(
      OutputRouter.render(.success(output), mode: text)
        == Rendered(
          stdout: "done\n", stderr: "warning: origin/x is behind [ref_stale]\n", exitCode: 0,
          errorCode: nil, warningCodes: ["ref_stale"]))
  }

  @Test func quietHidesSuccessTextButNotWarnings() {
    let output = CommandOutput(
      text: "done\n", data: Payload(), warnings: [OutputWarning(code: "w", message: "careful")])
    #expect(
      OutputRouter.render(.success(output), mode: OutputMode(json: false, quiet: true))
        == Rendered(
          stdout: "", stderr: "warning: careful [w]\n", exitCode: 0, errorCode: nil,
          warningCodes: ["w"]))
  }

  @Test(arguments: [false, true])
  func successInJSONModeIsOneEnvelopeLine(quiet: Bool) {
    let output = CommandOutput(
      text: "ignored", data: Payload(), warnings: [OutputWarning(code: "w", message: "careful")])
    #expect(
      OutputRouter.render(.success(output), mode: OutputMode(json: true, quiet: quiet))
        == Rendered(
          stdout: #"{"data":{"count":2,"name":"ä/b"},"ok":true,"schema":1,"#
            + #""warnings":[{"code":"w","message":"careful"}]}"# + "\n",
          stderr: "", exitCode: 0, errorCode: nil, warningCodes: ["w"]))
  }

  @Test func emptySuccessTextPrintsNothing() {
    let output = CommandOutput(text: "", data: Payload(), warnings: [])
    #expect(OutputRouter.render(.success(output), mode: text).stdout == "")
  }

  struct Unexpected: Error, CustomStringConvertible {
    var description = "index out of range\nat frame 3"
  }

  @Test func unexpectedErrorIsAnInternalEnvError() {
    #expect(
      OutputRouter.render(.failure(Unexpected()), mode: text)
        == Rendered(
          stdout: "",
          stderr:
            "error: internal error (bug): index out of range [env]\nask human: silta doctor\n",
          exitCode: 9, errorCode: .env))
  }

  @Test func unexpectedErrorDescriptionIsCapped() {
    let long = Unexpected(description: String(repeating: "x", count: 500))
    let stderr = OutputRouter.render(.failure(long), mode: text).stderr
    #expect(
      stderr.hasPrefix(
        "error: internal error (bug): " + String(repeating: "x", count: 200) + " [env]\n"))
  }
}
