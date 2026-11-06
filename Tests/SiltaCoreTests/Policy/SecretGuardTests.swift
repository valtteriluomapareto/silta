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
      Sample(rule: "github_pat", text: "gh" + "o_" + String(repeating: "Q", count: 36)),
      Sample(rule: "github_pat", text: "gh" + "u_" + String(repeating: "Q", count: 36)),
      Sample(rule: "github_pat", text: "gh" + "s_" + String(repeating: "Q", count: 36)),
      Sample(rule: "github_pat", text: "gh" + "r_" + String(repeating: "Q", count: 36)),
      Sample(rule: "github_pat", text: "github_" + "pat_" + String(repeating: "Q", count: 82)),
      Sample(rule: "azure_pat", text: legacyPAT),
      Sample(rule: "azure_pat", text: String(repeating: "Q", count: 75) + "AZ" + "DO" + "Q1234"),
      Sample(
        rule: "slack",
        text: "xo" + "xb-" + String(repeating: "1", count: 12) + "-"
          + String(repeating: "2", count: 12) + "-" + String(repeating: "Q", count: 24)),
      Sample(rule: "google", text: "AI" + "za" + String(repeating: "Q", count: 35)),
      Sample(rule: "anthropic", text: anthropicKey()),
      Sample(rule: "anthropic", text: anthropicKey(tag: "admin01")),
      Sample(rule: "anthropic", text: anthropicKey(tag: "oat01")),
      Sample(rule: "anthropic", text: "sk-" + "ant-" + String(repeating: "Q", count: 95)),
      Sample(
        rule: "jwt",
        text: "ey" + "JhY21lIjp0cnVlfQ.eyJhY21lIjoxfQ." + String(repeating: "q", count: 32)),
    ]
      + ["a", "p", "r", "s"].map { kind in
        Sample(rule: "slack", text: "xo" + "x\(kind)-" + String(repeating: "Q", count: 24))
      }
      // Every century sign, including the common `-` (1900s) and `+` (1800s).
      + "+-ABCDEFYXWVU".map { sign in Sample(rule: "hetu", text: identity(number: 2, sign: sign)) }
  }

  // Lowercase letters and digits: the alphabet both maintained Azure DevOps PAT
  // detectors match, so the fixture looks like a real legacy token.
  static var legacyPAT: String { String(repeating: "acme7zq3", count: 6) + "acme" }

  static var keyBlock: String {
    "-----BE" + "GIN RSA PRIVATE KEY-----\n" + String(repeating: "Q", count: 64)
      + "\n-----EN" + "D RSA PRIVATE KEY-----"
  }

  // Expected checks are computed from integer division independently of the scanner's digit fold.
  static func identity(number: Int, sign: Character = "A") -> String {
    let controls = Array("0123456789ABCDEFHJKLMNPRSTUVWXY")
    let value = 1_010_1000 + number
    return "010101" + String(sign) + String(format: "%03d", number) + String(controls[value % 31])
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
    let ref = "doc:" + Self.legacyPAT
    let clean = [
      "Acme backlog", sha40, sha64, uuid, ref, "AC-12/3", "app:platform-api",
      "Password=<placeholder>", "Password= <placeholder>", "Pwd=\"<acme-password>\"",
      "AccountKey=<key>",
      "?sig=<signature>", "eyJheader.eyJpayload.signature", "refs/heads/acme",
    ]
    let falsePositives = clean.filter { !SecretGuard.matches(in: $0).isEmpty }.count
    #expect(falsePositives == 0)
    for value in [sha40, sha64, uuid, ref] {
      #expect(SecretGuard.matches(in: value).isEmpty)
      // Explicit credential fields outrank otherwise clean candidate shapes.
      #expect(!SecretGuard.matches(in: "Password=" + value).isEmpty)
    }
    for value in clean.suffix(6) {
      #expect(SecretGuard.matches(in: value).isEmpty)
    }
  }

  // Long identifiers are ordinary text: a name, its `Tests` suffix, and a sentence
  // around it must survive untouched, whatever the rule set grows.
  @Test(arguments: [
    "aRepoPathHeldByAnotherWorkspaceNamesTheRepoAndHolder",
    "aRepoPathHeldByAnotherWorkspaceNamesTheRepoAndHolderBeforeTheTaskIsTriagedAndStarted",
    "repo_path_held_by_another_workspace_names_the_holder",
    "a_repo_path_held_by_another_workspace_names_the_repo_and_holder_before_it_is_triaged",
  ])
  func longIdentifiersAreNotSecrets(identifier: String) {
    #expect([52, 84].contains(identifier.count))
    for text in [
      identifier, identifier + "Tests", "see `" + identifier + "`",
      "The reply names " + identifier + " and its plan step.",
    ] {
      #expect(SecretGuard.matches(in: text).isEmpty)
      #expect(SecretGuard.redacted(text) == text)
    }
  }

  // Every rule, not just the Azure PAT one, must leave identifiers alone at the
  // lengths where a fixed-width rule could reach into them.
  @Test(arguments: [
    "proposingATaskForAnotherWorkspacesRepoKeepsItsSlugAndPrefixStableWhileWaitingForTriage",
    "hiddenBranchNamesStayOutOfAnotherWorkspacesProposedTaskList",
    "a_repo_path_held_by_another_workspace_names_the_repo_and_holder",
    "ACME_WORKSPACE_REPO_PATH_HELD_BY_ANOTHER_WORKSPACE_NAMES_ITS_HOLDER",
    "parseV2WorkspaceSlugAndPrefixFromTheScanRootBeforeRegisteringRepos",
    "repoPathHeldByAnotherWorkspaceNamesTheRepoAndItsHolderTodayV2",
  ])
  func otherRulesLeaveLongIdentifiersAlone(identifier: String) {
    #expect(SecretGuard.matches(in: identifier).isEmpty)
    #expect(SecretGuard.redacted(identifier) == identifier)
  }

  // Microsoft documents the AZDO marker at positions 76 through 80 of an
  // 84-character token, which leaves a 75- or 76-character prefix depending on
  // whether positions count from one.
  @Test(arguments: [75, 76])
  func currentPATsStayDetected(prefixLength: Int) {
    let token =
      String(repeating: "q", count: prefixLength) + "AZ" + "DO"
      + String(repeating: "7", count: 80 - prefixLength)
    #expect(token.count == 84)
    #expect(SecretGuard.redacted("token " + token) == "token [REDACTED:azure_pat]")
  }

  @Test func legacyPATsStayDetected() {
    #expect(Self.legacyPAT.count == 52)
    #expect(SecretGuard.redacted("token " + Self.legacyPAT) == "token [REDACTED:azure_pat]")
  }

  // Every permitted character, so narrowing the alphabet cannot silently drop one.
  @Test(arguments: Array("abcdefghijklmnopqrstuvwxyz0123456789"))
  func legacyPATsCoverTheWholeAlphabet(character: Character) {
    let token = String(repeating: "a", count: 51) + String(character)
    #expect(token.count == 52)
    #expect(SecretGuard.redacted("token " + token) == "token [REDACTED:azure_pat]")
  }

  // One uppercase letter is enough to make 52 characters an identifier, not a PAT.
  @Test(arguments: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
  func oneUppercaseLetterMakesALongIdentifierClean(letter: Character) {
    let identifier =
      String(repeating: "a", count: 25) + String(letter) + String(repeating: "a", count: 26)
    #expect(identifier.count == 52)
    #expect(SecretGuard.matches(in: identifier).isEmpty)
    #expect(SecretGuard.redacted(identifier) == identifier)
  }

  // Mixed case on both sides of AZDO must survive the current-format branch at both offsets.
  @Test(arguments: [75, 76])
  func currentPATsAcceptMixedCase(prefixLength: Int) {
    let prefix = String((0..<prefixLength).map { $0.isMultiple(of: 2) ? "Q" : "q" })
    let suffix = String((0..<(80 - prefixLength)).map { $0.isMultiple(of: 2) ? "R" : "7" })
    let token = prefix + "AZDO" + suffix
    #expect(token.count == 84)
    #expect(SecretGuard.redacted("token " + token) == "token [REDACTED:azure_pat]")
  }

  @Test func vendorTokenInsideARefStillRedacts() {
    let token = "AK" + "IA" + String(repeating: "Q", count: 16)
    let input = "doc:" + token
    #expect(SecretGuard.redacted(input) == "doc:[REDACTED:aws_key]")
  }

  @Test func distinctiveAzureTokenInsideARefIsRejected() {
    let token = String(repeating: "Q", count: 75) + "AZ" + "DO" + "Q1234"
    let input = "doc:" + token
    #expect(SecretGuard.redacted(input) == "doc:[REDACTED:azure_pat]")
  }

  @Test func base64URLTokensCoverAlphabetBoundaries() {
    for symbol in ["-", "_", "A", "0"] {
      for body in [
        symbol + String(repeating: "Q", count: 34), String(repeating: "Q", count: 34) + symbol,
      ] {
        let google = "AI" + "za" + body
        let jwt = "ey" + "JhY21lIjp0cnVlfQ.eyJhY21lIjoxfQ." + body
        for (rule, token) in [("google", google), ("jwt", jwt)] {
          #expect(SecretGuard.redacted(token) == "[REDACTED:\(rule)]")
        }
      }
    }
  }

  @Test func embeddedLegacyPATIsNotAWholeRefIdentifier() {
    let token = Self.legacyPAT
    let input = "doc:notes." + token + ".draft"
    #expect(SecretGuard.redacted(input) == "doc:notes.[REDACTED:azure_pat].draft")
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
    #expect(SecretGuard.version == 3)
  }

  @Test func rejectionAndWarningNeverStoreOrRenderMatches() throws {
    for sample in Self.samples {
      let error = SecretError(command: "silta task add '<title>' -F <file>", text: sample.text)
      let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
      let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
      for rendered in [text.stderr, json.stdout, String(reflecting: error)] {
        let exposed = rendered.contains(sample.text)
        #expect(!exposed)
      }
      #expect(text.exitCode == 1)
      #expect(error.code == .invalid)
      #expect(error.next == ["silta task add '<title>' -F <file> --allow-secret"])
    }
    let output = CommandOutput(text: "saved", data: "saved", warnings: [SecretGuard.warning])
    let text = OutputRouter.render(.success(output), mode: OutputMode(json: false))
    let json = OutputRouter.render(.success(output), mode: OutputMode(json: true))
    #expect(text.stderr == "warning: Secret content was redacted. [secret_redacted]\n")
    #expect(json.stdout.contains("secret_redacted"))
  }

  // A preview shows only a public marker: never a token's own characters or a birth date.
  @Test func previewsRevealNothingPrivate() throws {
    for (text, preview) in [
      (Self.identity(number: 2), "…[hetu]"),
      (Self.legacyPAT, "…[azure_pat]"),
      ("Pwd\t=acme", "Pwd…[password]"),
    ] {
      let match = try #require(SecretGuard.matches(in: text).first)
      #expect(match.preview(in: text) == preview)
    }
  }

  @Test func rejectionListsAtMostFivePreviews() {
    let token = "AK" + "IA" + String(repeating: "Q", count: 16)
    let error = SecretError(
      command: "silta task add", text: Array(repeating: token, count: 7).joined(separator: " "))
    let shown = Array(repeating: "AKIA…[aws_key]", count: 5).joined(separator: ", ")
    #expect(error.message == "Secret content detected: " + shown + " and 2 more")
    let five = Array(repeating: token, count: 5).joined(separator: " ")
    #expect(SecretError(command: "silta task add", text: five).message.hasSuffix(shown))
  }

  @Test func rejectionGolden() {
    let input = "Pass" + "word=acme-secret"
    let error = SecretError(command: "silta task add '<title>' -F <file>", text: input)
    let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
    let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
    Golden.forTests().check(text.stderr + json.stdout, "secret-error.txt")
  }
}

extension SecretGuardTests {
  // A synthetic key in the shape Anthropic's keys share: `sk-ant-`, a kind and version
  // tag, a dash, then a base64url body. A current API key's body is 95 characters ending
  // in `AA`; `length` counts the whole body. The prefix is split so this file holds no
  // contiguous key.
  static func anthropicKey(tag: String = "api03", length: Int = 95) -> String {
    let alphabet = Array("Qz7-x_Rk")
    let body = String((0..<(length - 2)).map { alphabet[$0 % alphabet.count] }) + "AA"
    return "sk-" + "ant-" + tag + "-" + body
  }

  // The whole key goes, wherever it sits; surrounding punctuation and quotes stay.
  @Test func anthropicKeysRedactWholeInContext() {
    let key = Self.anthropicKey()
    for (input, expected) in [
      ("ANTHROPIC_API_KEY=" + key, "ANTHROPIC_API_KEY=[REDACTED:anthropic]"),
      ("export ANTHROPIC_API_KEY='" + key + "'", "export ANTHROPIC_API_KEY='[REDACTED:anthropic]'"),
      ("x-api-key: " + key + "\n", "x-api-key: [REDACTED:anthropic]\n"),
      ("The key " + key + ". Rotate it.", "The key [REDACTED:anthropic]. Rotate it."),
      ("`" + key + "`", "`[REDACTED:anthropic]`"),
      ("note:" + key, "note:[REDACTED:anthropic]"),
      ("{\"log\":\"line1\\n" + key + "\"}", "{\"log\":\"line1\\n[REDACTED:anthropic]\"}"),
      ("key%3D" + key, "key%3D[REDACTED:anthropic]"),
      ("_" + key, "_[REDACTED:anthropic]"),
      ("token " + Self.anthropicKey(length: 200) + " end", "token [REDACTED:anthropic] end"),
    ] {
      #expect(SecretGuard.redacted(input) == expected)
    }
  }

  // Every base64url symbol at either end of the body, so narrowing the alphabet or
  // stopping short of the last character cannot leave part of a key behind.
  @Test(arguments: Array("AZaz09-_"))
  func anthropicKeysCoverTheBodyAlphabet(symbol: Character) {
    let body = String(repeating: "Q", count: 94)
    for key in [
      "sk-" + "ant-api03-" + String(symbol) + body,
      "sk-" + "ant-api03-" + body + String(symbol),
    ] {
      #expect(SecretGuard.redacted("token " + key + " end") == "token [REDACTED:anthropic] end")
    }
  }

  // Uppercase B is part of the base64url alphabet, so a body that contains one is
  // redacted whole, whether the B opens or closes the body.
  @Test func anthropicKeysRedactAnUppercaseBInTheBody() {
    let body = String(repeating: "Q", count: 94)
    for text in ["B" + body, body + "B"] {
      let key = "sk-" + "ant-api03-" + text
      #expect(SecretGuard.redacted("token " + key + " end") == "token [REDACTED:anthropic] end")
    }
  }

  // At least 80 characters after the prefix make a key, whatever the tag; anything
  // shorter is a fragment.
  @Test func anthropicKeysNeedEightyCharactersAfterThePrefix() {
    for tag in ["", "api03-"] {
      let body = String(repeating: "Q", count: 80 - tag.count)
      #expect(SecretGuard.redacted("sk-" + "ant-" + tag + body) == "[REDACTED:anthropic]")
      let fragment = "sk-" + "ant-" + tag + body.dropLast()
      #expect(SecretGuard.matches(in: fragment).isEmpty)
    }
  }

  // Talking about the prefix, quoting a masked hint or a short fragment, and naming
  // things after it are prose, not keys. A slug with 80 or more characters after
  // `sk-ant-` is redacted, which is the safe side.
  @Test(arguments: [
    "Anthropic keys start with sk-ant- and SecretGuard should catch them.",
    "sk-ant", "sk-ant-", "sk-ant-api03-", "sk-ant-…", "sk-ant-api03-…AA",
    "sk-ant-api03-Qz7x", "sk-ant-api03-Qz7-x_RkQz7-x_RkAA",
    "sk-ant-admin01-key-format-notes-for-the-secret-guard",
    "skAntApi03KeysAreRedactedFromCommentBodiesAndRecipientsBeforeStorage",
    "sk_ant_api03_keys_are_redacted_from_comment_bodies_and_recipients_before_storage",
    "testAnthropicKeysInCommentBodiesAndRecipientsAreRedactedBeforeTheyReachStorage",
  ])
  func anthropicProseIsNotASecret(text: String) {
    #expect(SecretGuard.matches(in: text).isEmpty)
    #expect(SecretGuard.redacted(text) == text)
  }
}
