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
