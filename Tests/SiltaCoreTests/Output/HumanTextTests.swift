import SiltaCore
import Testing

struct HumanTextTests {
  @Test func terminalProjectionPreservesLayoutAndUnicode() {
    let source =
      "cafe\u{301}\r\nrow\tcolumn\u{1b}esc\u{7}bell\u{7f}del\u{9b}c1 👩‍💻\u{2028}last\rparagraph\u{2029}end"
    let layout = "cafe\u{301}\nrow\tcolumn esc bell del c1 👩‍💻\nlast\nparagraph\nend"
    #expect(HumanText.body(source).utf8.elementsEqual(layout.utf8))
    let inline = "cafe\u{301}  row column esc bell del c1 👩‍💻 last paragraph end"
    #expect(HumanText.line(source).utf8.elementsEqual(inline.utf8))
  }

  @Test func theWholeFieldIsMaskedBeforeLayoutChanges() {
    let body = """
      -----BEGIN PGP PRIVATE KEY BLOCK-----
      Acme sample identifier
      -----END PGP PRIVATE KEY BLOCK-----
      Acme remaining paragraph
      """
    let seen = HumanText.body(body)
    #expect(seen.contains("[REDACTED:"))
    #expect(!seen.contains("Acme sample identifier"))
    #expect(seen.hasSuffix("Acme remaining paragraph"))
  }
}
