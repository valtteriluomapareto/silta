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
    ]
  }

  @Test(arguments: syntheticArmour)
  func privateArmourRedactsTheWholeRunAndKeepsFollowingProse(block: String) {
    let tail = "\nRead the Acme documentation."
    withKnownIssue("#255: Some private-key armour is not recognised.") {
      #expect(
        SecretGuard.redacted("Acme: " + block + tail) == "Acme: [REDACTED:private_key]" + tail)
      #expect(SecretGuard.redacted(block) == "[REDACTED:private_key]")
    }
  }

  @Test(arguments: ["ext", "service"])
  func longReferenceIdentifiersStayReadable(kind: String) {
    let ref = kind + ":" + Self.legacyPAT
    withKnownIssue("#255: The whole-ref exemption misses external parties and services.") {
      #expect(SecretGuard.redacted("Read `" + ref + "`.") == "Read `" + ref + "`.")
    }
    #expect(SecretGuard.redacted("Password=" + ref) == "[REDACTED:password]")
  }

  @Test(arguments: ["Password", "Pwd", "AccountKey"])
  func aMultiwordPlaceholderIsKeptWhole(field: String) {
    let input = field + "=<your Acme value here>"
    withKnownIssue("#255: An unquoted placeholder with spaces is partially redacted.") {
      #expect(SecretGuard.redacted(input) == input)
    }
  }

  @Test func sshTwoPublicKeyArmourIsOrdinaryText() {
    let input = "---- BEGIN SSH2 PUBLIC KEY ----\nAcme\n---- END SSH2 PUBLIC KEY ----"
    #expect(SecretGuard.redacted(input) == input)
  }
}
