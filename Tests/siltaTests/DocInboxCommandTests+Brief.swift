import Foundation
import SiltaTestSupport
import Testing

extension DocInboxCommandTests {
  @Test func briefCarriesTheSameBoundedDocumentEvidence() throws {
    try withScratchDirectory { scratch in
      let repo = try WhereCommandTests().setup(scratch)
      _ = try fixture(scratch)
      var result = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/script"),
        ["-q", "/dev/null", try SiltaBinary.url().path, "brief", "--ws", "acme", "--app", "api", "--json"],
        in: scratch, cwd: repo,
        environment: Self.environment.merging(["SILTA_ACTOR": "human:acme"]) { $1 })
      result.stdout = result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "^D\u{08}\u{08}", with: "")
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      let data = try TaskStateRegressionTests.data(result)
      let sections = try #require(data["sections"] as? [[String: Any]])
      let text = sections.filter { $0["id"] as? String == "inbox" }
        .compactMap { $0["text"] as? String }.joined()
      Golden.forTests().check(text, "brief-inbox-docs.txt")
      #expect((data["more"] as? [String])?.contains("silta --ws 'acme' inbox") == true)
      #expect(sections.allSatisfy { Set($0.keys) == ["id", "text"] })
      #expect(!text.contains(String(repeating: " ", count: 100)))
    }
  }
}
