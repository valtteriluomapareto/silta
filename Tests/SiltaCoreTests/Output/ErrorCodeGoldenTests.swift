import SiltaCore
import SiltaTestSupport
import Testing

/// Every error code rendered both ways; the golden was written from spec §16.
struct ErrorCodeGoldenTests {
  struct Sample: CodedError {
    var code: ErrorCode
    var message: String { "sample \(code.rawValue) error" }
    var next: [String] { ["silta sample --next"] }
    var retryAfter: Int? {
      switch code {
      case .rateLimited: 240
      case .busy: 3
      default: nil
      }
    }
  }

  @Test func everyCodeRendersPerTheSpec() {
    var out = ""
    for code in ErrorCode.allCases {
      let text = OutputRouter.render(.failure(Sample(code: code)), mode: OutputMode(json: false))
      let json = OutputRouter.render(.failure(Sample(code: code)), mode: OutputMode(json: true))
      out += "## \(code.rawValue) (exit \(text.exitCode))\n\(text.stderr)\(json.stdout)\n"
    }
    Golden.forTests().check(out, "error-codes.txt")
  }
}
