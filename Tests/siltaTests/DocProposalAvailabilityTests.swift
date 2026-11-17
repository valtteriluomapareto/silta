import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct DocProposalAvailabilityTests {
  @Test func submissionAndHumanDecisionsAreAvailable() throws {
    try withScratchDirectory { scratch in
      for args in [["guide", "docs"], ["guide", "docs", "--json"]] {
        let result = try SiltaBinary.run(args, in: scratch)
        #expect(result.termination == .exit(0))
        let text =
          args.contains("--json")
          ? try #require(try GuideContractTests.data(result)["text"] as? String) : result.stdout
        #expect(text.contains("doc triage --accept"))
        #expect(!text.contains("cannot decide proposals yet"))
        #expect(text.contains("Map gap:"))
        #expect(text.contains("never create a task or file for a map gap"))
      }
      let schema = try GuideContractTests.data(
        SiltaBinary.run(["schema", "doc", "--json"], in: scratch))
      let commands = try #require(schema["commands"] as? [[String: Any]])
      #expect(
        Set(commands.compactMap { $0["name"] as? String }) == [
          "silta doc show", "silta doc ls", "silta doc edit", "silta doc archive",
          "silta doc propose", "silta doc triage",
        ])
    }
  }
}
