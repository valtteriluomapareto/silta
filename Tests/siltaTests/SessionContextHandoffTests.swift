import Foundation
import SiltaTestSupport
import Testing

struct SessionContextHandoffTests {
  @Test(arguments: ["plan", "link"])
  func contextOnlyHandoffClearsEarlierOwnEvents(action: String) throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let write =
        action == "plan"
        ? ["task", "plan", "AC-1", "-m", "- [ ] Acme next"]
        : ["task", "link", "AC-1", "url:https://example.invalid/acme"]
      for args in [
        ["task", "add", "Acme work", "--start"], write,
        ["task", "submit", "AC-1"],
        ["comment", "AC-1", "--kind", "handoff", "-m", "State: Acme saved. Next: review."],
        ["task", "start", "AC-1"],
      ] {
        #expect(try SessionCheckTests.run(args, in: scratch).termination == .exit(0))
      }
      let pending = try SessionCheckTests.tasks(in: scratch)
      #expect(pending.isEmpty)
      _ = try SessionCheckTests.run(
        ["task", "plan", "AC-1", "-m", "- [ ] Acme follow-up"], in: scratch)
      #expect(try SessionCheckTests.tasks(in: scratch).count == 1)
    }
  }
}

extension SessionContextHandoffTests {
  @Test(arguments: ["plan", "comment"])
  func foreignHandoffCannotEraseOwnWrite(kind: String) throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      for args in [
        ["task", "add", "Acme work", "--start"],
        ["comment", "AC-1", "--kind", "handoff", "-m", "State: Acme saved. Next: review."],
      ] {
        #expect(try SessionCheckTests.run(args, in: scratch).termination == .exit(0))
      }
      let ownWrite =
        kind == "plan"
        ? ["task", "plan", "AC-1", "-m", "- [ ] Acme follow-up"]
        : ["comment", "AC-1", "-m", "Acme new context"]
      #expect(try SessionCheckTests.run(ownWrite, in: scratch).termination == .exit(0))
      try Self.assertUnclaimed(in: scratch)
      var foreign = SessionCheckTests.environment
      foreign["SILTA_SESSION"] = "acme-other-session"
      #expect(
        try SessionCheckTests.run(
          [
            "comment", "AC-1", "--kind", "handoff", "-m",
            "State: Acme other context. Next: review.",
          ],
          in: scratch, environment: foreign
        ).termination == .exit(0))
      try Self.assertUnclaimed(in: scratch)
      #expect(
        try SessionCheckTests.run(["task", "start", "AC-1"], in: scratch).termination == .exit(0))
      let reclaimed = try AgentsInstallTests.data(
        SessionCheckTests.run(["task", "show", "AC-1", "--json"], in: scratch))
      #expect(reclaimed["claimed_by"] as? String == "agent:claude:acme-session")
      #expect(try SessionCheckTests.tasks(in: scratch) == [["workspace": "acme", "ref": "AC-1"]])
      for args in [
        [
          "comment", "AC-1", "--kind", "handoff", "-m",
          "State: Acme follow-up saved. Next: review.",
        ],
        ["task", "start", "AC-1"],
      ] {
        #expect(try SessionCheckTests.run(args, in: scratch).termination == .exit(0))
      }
      #expect(try SessionCheckTests.tasks(in: scratch).isEmpty)
    }
  }

  private static func assertUnclaimed(in scratch: URL) throws {
    let data = try AgentsInstallTests.data(
      SessionCheckTests.run(["task", "show", "AC-1", "--json"], in: scratch))
    #expect(data["claimed_by"] == nil)
  }
}
