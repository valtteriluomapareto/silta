import SiltaCore
import Testing

extension SecretGuardTests {
  static var syntheticArmour: [String] {
    let body = String(repeating: "Q", count: 64)
    return [
      "-----BE" + "GIN PGP PRIVATE KEY BLOCK-----\n" + body
        + "\n-----EN" + "D PGP PRIVATE KEY BLOCK-----",
      "---- BE" + "GIN SSH2 ENCRYPTED PRIVATE KEY ----\n" + body
        + "\n---- EN" + "D SSH2 ENCRYPTED PRIVATE KEY ----",
      "-----BE" + "GIN RSA PRIVATE KEY-----\n" + body,
      "-----BE" + "GIN PGP PRIVATE KEY BLOCK-----\r\nVersion: Acme\r\n\r\n" + body
        + "\r\n=QQQQ",
      "---- BE" + "GIN SSH2 ENCRYPTED PRIVATE KEY ----\nComment: Acme fixture" + "\\"
        + "\ncontinued sample metadata.\n" + body,
    ]
  }

  @Test(arguments: samples) func corpusFindsEveryRequiredRule(sample: Sample) throws {
    let suffix = sample.rule == "private_key" ? "\nEnd." : " end"
    let separator = sample.rule == "private_key" && !sample.text.contains("END ") ? "\n" : " "
    let prefix = "Acme 🦊" + separator
    let input = prefix + sample.text + suffix
    let matches = SecretGuard.matches(in: input)
    let detected = matches.contains { $0.rule == sample.rule }
    #expect(detected, "missing rule \(sample.rule)")
    let output = SecretGuard.redacted(input)
    let leaked = output.contains(sample.text)
    #expect(!leaked, "unredacted \(sample.rule)")
    #expect(output.contains("[REDACTED:\(sample.rule)]"))
    if sample.rule == "private_key" {
      #expect(output == prefix + "[REDACTED:private_key]" + suffix)
    }
    for match in matches {
      let preview = match.preview(in: input)
      let entire = String(input[match.range])
      let exposed = preview.contains(entire)
      #expect(!exposed)
      #expect(preview.hasSuffix("…[\(match.rule)]"))
    }
  }

  @Test(arguments: syntheticArmour)
  func privateArmourRedactsTheWholeRunAndKeepsFollowingProse(block: String) {
    let tail = "\nRead the Acme documentation."
    let prefix = block.contains("END ") ? "Acme: " : "Acme:\n"
    #expect(SecretGuard.redacted(prefix + block + tail) == prefix + "[REDACTED:private_key]" + tail)
    #expect(SecretGuard.redacted(block) == "[REDACTED:private_key]")
  }

  @Test func anUnfinishedBlockDoesNotConsumeProseBeforeTheNextBlock() {
    let prose = "\nRead the Acme documentation.\n"
    let complete = Self.syntheticArmour[0]
    let incomplete = Self.syntheticArmour[2]
    #expect(
      SecretGuard.redacted(incomplete + prose + complete)
        == "[REDACTED:private_key]" + prose + "[REDACTED:private_key]")
  }

  @Test(arguments: ["> ", "- ", "12. ", "> - > "], ["\n", "\r\n"])
  func unfinishedMarkdownArmourMasksTheEntireBody(prefix: String, newline: String) {
    let start = "-----BE" + "GIN RSA PRIVATE KEY-----"
    let first = String(repeating: "Q", count: 64)
    let second = String(repeating: "Z", count: 44) + "=="
    let tail = [prefix, prefix + "Read the Acme documentation."].joined(separator: newline)
    let original = ([start, first, second].map { prefix + $0 } + [tail]).joined(
      separator: newline)
    let expected = prefix + "[REDACTED:private_key]" + newline + tail
    let framed = HumanText.framed(original)
    #expect(framed.utf8.count { $0 == 10 } == original.utf8.count { $0 == 10 })
    #expect(SecretGuard.redacted(original) == expected && !framed.contains(first))
  }

  @Test(arguments: ["paragraph", "numbered", "leading"])
  func inlineArmourMentionsKeepTheRestOfTheDocument(style: String) {
    let start = "-----BE" + "GIN PRIVATE KEY-----"
    let line =
      switch style {
      case "numbered": "42. Verify the marker `" + start + "` in the manual."
      case "leading": start + " is the example marker."
      default: "The manual prints `" + start + "` before the key."
      }
    let original = line + "\n\nDone\nVerify\n"
    #expect(
      SecretGuard.matches(in: original).isEmpty && SecretGuard.redacted(original) == original)
  }

  @Test(arguments: ["ext", "service"])
  func longReferenceIdentifiersStayReadable(kind: String) {
    let ref = kind + ":" + Self.legacyPAT
    #expect(SecretGuard.redacted("Read `" + ref + "`.") == "Read `" + ref + "`.")
    #expect(SecretGuard.redacted("Password=" + ref) == "[REDACTED:password]")
  }

  @Test(arguments: ["Password", "Pwd", "AccountKey"])
  func aMultiwordPlaceholderIsKeptWhole(field: String) {
    let input = field + "=<your Acme value here>"
    #expect(SecretGuard.redacted(input) == input)
  }

  @Test func recognizedReferenceIdentitySlotsStayReadable() {
    let id = Self.legacyPAT
    let refs = [
      "app:" + id, "topic:" + id, "doc:" + id + "@1/2",
      "edge:" + id + "/web/calls", "edge:web/" + id + "/calls",
      "edge:web/service:" + id + "/calls", "edge:web/api/" + id,
      "code:" + id + "@main:src/Rules.swift#L1-2", id + ":src/Rules.swift",
      "task:" + id + "-12", id + "-12/3",
    ]
    for ref in refs {
      #expect(SecretGuard.redacted("Read `" + ref + "`.") == "Read `" + ref + "`.")
    }
  }

  @Test func tokenInsideALongerValueStillRedacts() {
    let token = Self.legacyPAT
    for input in [
      "service:" + token + "%2Fchild",
      "ext:prefix-" + token,
      "url:https://acme.example/path/service:" + token,
      "url:https://acme.example/?service:" + token,
      "service:" + token + "/child",
      "code:acme:src/" + token,
      "edge:web/service:" + token + "%2Fchild/calls",
      "url:https://acme.example/(service:" + token + ")",
    ] {
      #expect(SecretGuard.matches(in: input).map(\.rule) == ["azure_pat"])
      #expect(!SecretGuard.redacted(input).contains(token))
    }
    #expect(SecretGuard.redacted("Password=<your Acme value>tail") == "[REDACTED:password]")
    #expect(SecretGuard.redacted("AccountKey=<your Acme value>tail") == "[REDACTED:azure_key]")
  }

  @Test func sshTwoPublicKeyArmourIsOrdinaryText() {
    let input = "---- BEGIN SSH2 PUBLIC KEY ----\nAcme\n---- END SSH2 PUBLIC KEY ----"
    #expect(SecretGuard.redacted(input) == input)
  }
}
