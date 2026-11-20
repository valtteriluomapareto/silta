import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DocEditCommandTests {
  @Test(arguments: [false, true])
  func storedAndExportedDocsHandleUnfinishedArmour(quote: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let marker = "-----BE" + "GIN PRIVATE KEY-----"
      let payload = String(repeating: "Q", count: 64)
      let inline = "The Acme guide shows `" + marker + "`.\n\nDone\nVerify."
      let original =
        quote ? "> " + marker + "\n> " + payload + "\n\nDone\n\nKeep these instructions." : inline
      let expected = quote ? "> [REDACTED:private_key]\n\nDone\n\nKeep these instructions." : inline
      let body = try Self.input(scratch, original)
      let written = try Self.run(["rules"] + Self.creation + ["-F", body.path], scratch)
      try #require(written.termination == .exit(0), "\(written.stdout)\(written.stderr)")
      let warnings = try TaskStateCommandTests.warnings(written)
      let stored = try store.read { try String.fetchOne($0, sql: "SELECT body_md FROM doc_rev") }
      let exported = try SiltaBinary.run(["--ws", "acme", "export"], in: scratch)
      try #require(exported.termination == .exit(0), "\(exported.stdout)\(exported.stderr)")
      let file = scratch.appending(path: "silta-home/exports/acme/docs/rules.md")
      let snapshot = try String(contentsOf: file, encoding: .utf8)
      #expect(warnings.contains("secret_redacted") == quote)
      #expect(stored == expected)
      #expect(snapshot.contains("\n" + expected + "\n") && !snapshot.contains(payload))
    }
  }
}
