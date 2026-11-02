import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

struct SecretGuardTests {
  struct Sample: Sendable, CustomTestStringConvertible {
    var testDescription: String { rule }
    let rule: String
    let text: String
  }

  static var samples: [Sample] {
    [
      Sample(rule: "private_key", text: keyBlock),
      Sample(rule: "private_key", text: keyBlock.replacingOccurrences(of: "\n", with: "\r\n")),
      Sample(
        rule: "azure_key", text: "Account" + "Key=" + String(repeating: "Q", count: 44) + "=="),
      Sample(rule: "sas", text: "url:https://blob.acme.example/?sv=1&" + "sig=abcd%2Befgh%3D"),
      Sample(rule: "password", text: "Server=acme;Pass" + "word=acme-secret;Database=acme"),
      Sample(rule: "password", text: "PWD='acme secret'"),
      Sample(rule: "password", text: "Pwd=x"),
      Sample(rule: "password", text: "PWD='\u{001B}x'"),
      Sample(rule: "aws_key", text: "AK" + "IA" + String(repeating: "Q", count: 16)),
      Sample(rule: "aws_key", text: "AS" + "IA" + String(repeating: "R", count: 16)),
      Sample(rule: "github_pat", text: "gh" + "p_" + String(repeating: "Q", count: 36)),
      Sample(rule: "github_pat", text: "github_" + "pat_" + String(repeating: "Q", count: 82)),
      Sample(rule: "azure_pat", text: String(repeating: "Q", count: 52)),
      Sample(rule: "azure_pat", text: String(repeating: "Q", count: 75) + "AZ" + "DO" + "Q1234"),
      Sample(
        rule: "slack",
        text: "xo" + "xb-" + String(repeating: "1", count: 12) + "-"
          + String(repeating: "2", count: 12) + "-" + String(repeating: "Q", count: 24)),
      Sample(rule: "google", text: "AI" + "za" + String(repeating: "Q", count: 35)),
      Sample(
        rule: "jwt",
        text: "ey" + "JhY21lIjp0cnVlfQ.eyJhY21lIjoxfQ." + String(repeating: "q", count: 32)),
      Sample(rule: "hetu", text: identity(number: 2)),
    ]
  }

  static var keyBlock: String {
    "-----BE" + "GIN RSA PRIVATE KEY-----\n" + String(repeating: "Q", count: 64)
      + "\n-----EN" + "D RSA PRIVATE KEY-----"
  }

  // Expected checks are computed from integer division independently of the scanner's digit fold.
  static func identity(number: Int) -> String {
    let controls = Array("0123456789ABCDEFHJKLMNPRSTUVWXY")
    let value = 1_010_1000 + number
    return "010101" + "A" + String(format: "%03d", number) + String(controls[value % 31])
  }

  @Test(arguments: samples) func corpusFindsEveryRequiredRule(sample: Sample) throws {
    let input = "Acme 🦊 " + sample.text + " end"
    let matches = SecretGuard.matches(in: input)
    let detected = matches.contains { $0.rule == sample.rule }
    #expect(detected, "missing rule \(sample.rule)")
    let output = SecretGuard.redacted(input)
    let leaked = output.contains(sample.text)
    #expect(!leaked, "unredacted \(sample.rule)")
    #expect(output.contains("[REDACTED:\(sample.rule)]"))
    for match in matches {
      let preview = match.preview(in: input)
      let entire = String(input[match.range])
      let exposed = preview.contains(entire)
      #expect(!exposed)
      #expect(preview.hasSuffix("…[\(match.rule)]"))
    }
  }

  @Test func cleanCorpusAndAllowlists() {
    let sha40 = String(repeating: "a1", count: 20)
    let sha64 = String(repeating: "b2", count: 32)
    let uuid = "12345678-1234-1234-1234-123456789abc"
    let ref = "doc:" + String(repeating: "Q", count: 52)
    let clean = [
      "Acme backlog", sha40, sha64, uuid, ref, "AC-12/3", "app:platform-api",
      "Password=<placeholder>", "Password= <placeholder>", "Pwd=\"<acme-password>\"",
      "AccountKey=<key>",
      "?sig=<signature>", "eyJheader.eyJpayload.signature", "refs/heads/acme",
    ]
    let falsePositives = clean.filter { !SecretGuard.matches(in: $0).isEmpty }.count
    #expect(falsePositives <= 1)
    for value in [sha40, sha64, uuid, ref] {
      #expect(SecretGuard.matches(in: value).isEmpty)
      // Explicit credential fields outrank otherwise clean candidate shapes.
      #expect(!SecretGuard.matches(in: "Password=" + value).isEmpty)
    }
    for value in clean.suffix(6) {
      #expect(SecretGuard.matches(in: value).isEmpty)
    }
  }

  @Test func vendorTokenInsideARefStillRedacts() {
    let token = "AK" + "IA" + String(repeating: "Q", count: 16)
    let input = "doc:" + token
    #expect(SecretGuard.redacted(input) == "doc:[REDACTED:aws_key]")
  }

  @Test func distinctiveAzureTokenInsideARefIsRejected() {
    let token = String(repeating: "Q", count: 75) + "AZ" + "DO" + "Q1234"
    let input = "doc:" + token
    withKnownIssue("#8: new-format Azure token was exempted as a ref") {
      #expect(SecretGuard.redacted(input) == "doc:[REDACTED:azure_pat]")
    }
  }

  @Test func base64URLTokensCanEndWithHyphens() {
    let google = "AI" + "za" + String(repeating: "Q", count: 34) + "-"
    let jwt = "ey" + "JhY21lIjp0cnVlfQ.eyJhY21lIjoxfQ." + String(repeating: "q", count: 31) + "-"
    for (rule, token) in [("google", google), ("jwt", jwt)] {
      withKnownIssue("#8: word boundaries miss or truncate base64url suffix punctuation") {
        #expect(SecretGuard.redacted(token) == "[REDACTED:\(rule)]")
      }
    }
  }

  @Test func checksumRejectsPatternOnlyFalsePositives() {
    for (number, control) in [(2, "S"), (3, "T"), (10, "1"), (31, "P"), (299, "B"), (899, "P")] {
      let valid = "010101" + "A" + String(format: "%03d", number) + control
      #expect(SecretGuard.matches(in: valid).map(\.rule) == ["hetu"])
      let wrong = valid.dropLast() + (valid.last == "0" ? "1" : "0")
      #expect(SecretGuard.matches(in: String(wrong)).isEmpty)
    }
  }

  @Test func crossingOverlapsCoverTheEntireSecret() throws {
    let input = "Password=" + Self.keyBlock + " after"
    let matches = SecretGuard.matches(in: input)
    let match = try #require(matches.first)
    #expect(matches.count == 1)
    #expect(match.rule == "password")
    #expect(SecretGuard.redacted(input) == "[REDACTED:password] after")
  }

  @Test func repeatedSecretsAndUnicodePreserveSurroundingText() {
    let token = "AK" + "IA" + String(repeating: "Q", count: 16)
    let input = "🦊 " + token + " 🦊 " + token + "!"
    #expect(SecretGuard.redacted(input) == "🦊 [REDACTED:aws_key] 🦊 [REDACTED:aws_key]!")
    #expect(SecretGuard.version == 1)
  }

  @Test func rejectionAndWarningNeverStoreOrRenderMatches() throws {
    for sample in Self.samples {
      let error = SecretError(command: "silta task add -F -", text: sample.text)
      let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
      let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
      for rendered in [text.stderr, json.stdout, String(reflecting: error)] {
        let exposed = rendered.contains(sample.text)
        #expect(!exposed)
      }
      #expect(text.exitCode == 1)
      #expect(error.code == .invalid)
      #expect(error.next == ["silta task add -F - --allow-secret"])
    }
    let output = CommandOutput(text: "saved", data: "saved", warnings: [SecretGuard.warning])
    let text = OutputRouter.render(.success(output), mode: OutputMode(json: false))
    let json = OutputRouter.render(.success(output), mode: OutputMode(json: true))
    #expect(text.stderr == "warning: Secret content was redacted. [secret_redacted]\n")
    #expect(json.stdout.contains("secret_redacted"))
  }

  @Test func rejectionGolden() {
    let input = "Pass" + "word=acme-secret"
    let error = SecretError(command: "silta task add -F -", text: input)
    let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
    let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
    Golden.forTests().check(text.stderr + json.stdout, "secret-error.txt")
  }
}
