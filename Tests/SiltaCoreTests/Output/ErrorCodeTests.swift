import SiltaCore
import Testing

struct ErrorCodeTests {
  @Test func onlyHumanCodesSendNextToTheHuman() {
    let human = ErrorCode.allCases.filter { $0.nextBy == .human }.map(\.rawValue)
    #expect(human == ["human_only", "env"])
  }

  // The "Agent should" column of the spec §16 table; `read_only_promoted` has its own row.
  static let agentShould: [Int32: String] = [
    1: "Read `silta <cmd> --help` and fix the call",
    2: "Check the ref, or carry on without silta",
    3:
      "Stop and ask the human in chat; rerun with `--approved \"<their words>\"` "
      + "after they say yes",
    4: "Retry with `--ws <slug>` for workspace ambiguity or `--app <slug>` for app ambiguity",
    5: "Retry once after a few seconds",
    6: "Re-read, then decide; don't steal, and don't unblock while blockers are open",
    7: "Request a review or ask the human",
    8: "Wait for `retry_after_s`, or summarise",
    9: "Report the printed fix to the human",
  ]

  @Test(arguments: ErrorCode.allCases)
  func agentShouldMatchesTheSpec(code: ErrorCode) {
    let promoted = "Leave it to its tracker and pick other work"
    #expect(
      code.agentShould
        == (code == .readOnlyPromoted ? promoted : Self.agentShould[code.exitCode]))
  }
}
