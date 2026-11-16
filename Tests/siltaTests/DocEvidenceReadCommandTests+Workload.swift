import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DocEvidenceReadCommandTests {
  @Test(arguments: ["disjoint", "blocks", "history"])
  func largeBodyReplacementKeepsBoundedPinnedRead(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let old: String
      let new: String
      switch mode {
      case "blocks":
        old = (Array(repeating: "A", count: 16_384) + Array(repeating: "B", count: 16_384))
          .joined(separator: "\n")
        new = (Array(repeating: "B", count: 16_384) + Array(repeating: "A", count: 16_384))
          .joined(separator: "\n")
      case "history":
        old = String(repeating: "A\n", count: 40_000)
        new = "New body"
      default:
        old = Array(repeating: "A", count: 32_768).joined(separator: "\n")
        new = Array(repeating: "B", count: 32_768).joined(separator: "\n")
      }
      #expect((old.utf8.count > 65_536) == (mode == "history"))
      #expect(new.utf8.count <= 65_536)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT) WHERE rev=1",
          arguments: [Data(old.utf8)])
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT) WHERE rev=2",
          arguments: [Data(new.utf8)])
      }
      let before = try truth(store)
      let result = try run(["--diff"], scratch)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      #expect(result.stdout.split(separator: "\n").count <= 400)
      let next =
        result.stdout.components(separatedBy: "\n").first {
          $0.contains("lines omitted; next:")
        } ?? ""
      #expect(next.contains("doc:rules@2") && next.contains(" --diff --lines "))
      #expect(try truth(store) == before)
    }
  }
}
