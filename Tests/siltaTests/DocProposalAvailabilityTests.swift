import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct DocProposalAvailabilityTests {
  @Test func restoredProposalsAreReadOnlyInPublishedGuide() throws {
    try withScratchDirectory { scratch in
      for args in [["guide", "docs"], ["guide", "docs", "--json"]] {
        let result = try SiltaBinary.run(args, in: scratch)
        #expect(result.termination == .exit(0))
        let text =
          args.contains("--json")
          ? try #require(try GuideContractTests.data(result)["text"] as? String) : result.stdout
        #expect(text.contains("cannot submit or decide them"))
        #expect(text.contains("Map gap:"))
        #expect(text.contains("never create a task or file for a map gap"))
      }
      let schema = try GuideContractTests.data(
        SiltaBinary.run(["schema", "doc", "--json"], in: scratch))
      let commands = try #require(schema["commands"] as? [[String: Any]])
      #expect(
        Set(commands.compactMap { $0["name"] as? String }) == [
          "silta doc show", "silta doc ls", "silta doc edit", "silta doc archive",
        ])
    }
  }

  @Test(arguments: [false, true])
  func unavailableTriageDoesNotReadDocumentMetrics(privateReport: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try DogfoodReportTests.setup(scratch)
      try store.write {
        try $0.database.execute(sql: "ALTER TABLE doc_rev RENAME TO deferred_doc_rev")
      }
      let before = try store.read {
        try String.fetchAll(
          $0, sql: "SELECT name||':'||coalesce(sql,'') FROM sqlite_master ORDER BY name")
      }
      let tools = try DogfoodReportTests.tools(scratch)
      let flags = (privateReport ? ["--ws", "silta"] : []) + ["--since", "2023-11-14"]
      let result = try DogfoodReportTests.run(flags, scratch: scratch, tools: tools)
      try #require(result.termination == .exit(0), "\(result.stderr)")
      let text: String
      if privateReport {
        let file = DogfoodPrivateReportTests.folder(scratch, "silta")
          .appending(path: "2023-11-30.md")
        text = try String(contentsOf: file, encoding: .utf8)
        #expect(try DogfoodPrivateReportTests.permissions(file) == 0o600)
      } else {
        text = result.stdout
      }
      #expect(text.contains("## Human load"))
      #expect(text.contains("Proposals accepted: 5; dropped: 1;"))
      #expect(!text.contains("## Document proposals") && !text.contains("doc-triage"))
      #expect(
        try store.read {
          try String.fetchAll(
            $0, sql: "SELECT name||':'||coalesce(sql,'') FROM sqlite_master ORDER BY name")
        } == before)
    }
  }
}
