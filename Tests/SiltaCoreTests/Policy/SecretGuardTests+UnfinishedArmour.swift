import SiltaCore
import Testing

extension SecretGuardTests {
  private static let opener = "-----BE" + "GIN PRIVATE KEY-----"
  private static let masked = "[REDACTED:private_key]"
  private static let payload = String(repeating: "Q", count: 64)

  @Test(arguments: [#"\n"#, #"\r\n"#])
  func escapedArmourKeepsFollowingFields(separator: String) {
    let prefix = #"Acme 🦊 {"credential":""#
    let suffix = #"","keep":"Documentation."}"#
    let input = prefix + Self.opener + separator + Self.payload + separator + Self.payload + suffix
    #expect(SecretGuard.redacted(input) == prefix + Self.masked + suffix)
  }

  @Test(arguments: ["annotated", "flat", "bom", "nbsp", "pem"])
  func unfinishedArmourNeedsActualPayloadEvidence(form: String) {
    let (input, expected) = Self.armourExample(form)
    #expect(SecretGuard.redacted(input) == expected)
    #expect(!HumanText.framed(input).contains(Self.payload))
    #expect(HumanText.framed(input).utf8.count { $0 == 10 } == input.utf8.count { $0 == 10 })
  }

  private static func armourExample(_ form: String) -> (String, String) {
    let tail = "\nRead the Acme guide."
    switch form {
    case "flat":
      let prefix = "Acme 🦊: "
      let suffix = "\", then keep this prose."
      return (
        prefix + opener + " " + String(payload.prefix(40)) + "==" + suffix,
        prefix + masked + suffix
      )
    case "annotated":
      return ("Acme: " + opener + " (truncated)\n" + payload + tail, "Acme: " + masked + tail)
    case "pem":
      let body = "\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,ABCD\n\n" + payload
      return ("Acme: " + opener + body + tail, "Acme: " + masked + tail)
    default:
      let prefix = form == "bom" ? "\u{feff}" : "\u{00a0}> "
      let linePrefix = form == "bom" ? "" : "> "
      return (prefix + opener + "\n" + linePrefix + payload + tail, prefix + masked + tail)
    }
  }

  @Test func shortRunsAndUnrelatedTypedIdentifiersStayReadable() {
    let example = "Acme: " + Self.opener + " " + String(Self.payload.prefix(39)) + "=="
    let mention =
      "Read `" + Self.opener + "` before verifying code:"
      + String(repeating: "a", count: 40) + ":manual.md."
    #expect(SecretGuard.redacted(example) == example)
    #expect(SecretGuard.redacted(mention) == mention)
  }

  @Test(arguments: ["", "> ", "- ", "3. "])
  func firstAndSeparatedPayloadsKeepShortProse(prefix: String) {
    let first = String(Self.payload.prefix(15)) + "="
    let length16 = String(Self.payload.prefix(16))
    let start = prefix + Self.opener
    let bodyPrefix = prefix == "> " ? prefix : String(repeating: " ", count: prefix.count)
    let after = "\n\n" + bodyPrefix + first + "\n"
    let shortFirst = start + "\n" + bodyPrefix + first + "\n"
    let shortAfterBlank = start + "\n" + bodyPrefix + length16 + after
    let expected = prefix + Self.masked + "\n" + bodyPrefix + first + "\n"
    #expect(SecretGuard.redacted(shortFirst) == expected)
    #expect(SecretGuard.redacted(shortAfterBlank) == prefix + Self.masked + after)
    let continued = start + "\n" + bodyPrefix + length16 + "\n\n" + bodyPrefix + length16
    #expect(SecretGuard.redacted(continued) == prefix + Self.masked)
  }

  @Test(arguments: ["> ", "- ", "3. "])
  func aBlankBeforeTheFirstPayloadCanEndTheMarkdownContainer(prefix: String) {
    let tail = "\n\n" + Self.payload + "\nRead this."
    let input = prefix + Self.opener + tail
    #expect(SecretGuard.redacted(input) == prefix + Self.masked + tail)
  }

  @Test(arguments: ["\n\nDone", "\n\nVerify", "\n\n- Done", "\n\nComment: see the guide below"])
  func standaloneOpenerKeepsFollowingProse(tail: String) {
    #expect(SecretGuard.redacted(Self.opener + tail) == Self.masked + tail)
  }
}
