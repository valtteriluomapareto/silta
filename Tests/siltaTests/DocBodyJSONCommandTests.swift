import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocBodyJSONCommandTests {
  @Test(arguments: [false, true])
  func jsonFieldsAndSchemaMatchTheVisibleBody(quiet: Bool) throws {
    withKnownIssue {
      try withScratchDirectory { scratch in
        _ = try DocReadCommandTests().fixture(scratch)
        let args = ["--ws", "acme", "doc", "show", "rules"]
        let text = try SiltaBinary.run(args, in: scratch)
        let result = try SiltaBinary.run(
          args + ["--json"] + (quiet ? ["--quiet"] : []), in: scratch)
        let data = try GuideContractTests.data(result)
        #expect(data["output"] as? String == text.stdout)
        #expect(data["body"] as? String == "Accepted body")
        #expect(data["title"] as? String == "Push rules")
        #expect(data["about"] as? [String] == ["app:api"])
        #expect(data["state"] as? String == "accepted")
        let schema = try GuideContractTests.data(
          SiltaBinary.run(["schema", "doc", "show", "--json"], in: scratch))
        let commands = try #require(schema["commands"] as? [[String: Any]])
        let shape = try #require(commands.first?["data"] as? [String: Any])
        let fields = try #require(shape["object"] as? [String: Any])
        #expect(Set(fields.keys) == ["ref", "output", "body", "title", "about", "state"])
        #expect(fields["body"] as? [String: String] == ["optional": "string"])
        #expect(ShapeCheck.violations(of: data, against: shape).isEmpty)
      }
    }
  }

  @Test func nonBodyCommandsDoNotGainBodyFields() throws {
    try withScratchDirectory { scratch in
      _ = try DocDiscussionReadCommandTests().fixture(scratch)
      for selection in [
        ["doc:rules@3", "--diff"], ["doc:rules@3", "--comments"], ["doc:rules@3/2"],
      ] {
        let result = try SiltaBinary.run(
          ["--ws", "acme", "doc", "show"] + selection + ["--json"], in: scratch)
        #expect(result.termination == .exit(0))
        #expect(Set(try GuideContractTests.data(result).keys) == ["ref", "output"])
      }
    }
  }
}
