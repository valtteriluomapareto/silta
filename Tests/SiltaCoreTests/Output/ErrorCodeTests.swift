import SiltaCore
import Testing

struct ErrorCodeTests {
  // Copied from the spec §16 table, not from the code.
  static let table: [(String, Int32)] = [
    ("usage", 1), ("invalid", 1),
    ("not_found", 2), ("unregistered", 2),
    ("human_only", 3), ("read_only_promoted", 3),
    ("ambiguous_location", 4),
    ("busy", 5),
    ("conflict", 6), ("claimed", 6), ("stale_rev", 6), ("lease_taken", 6),
    ("gate", 7),
    ("rate_limited", 8),
    ("env", 9),
  ]

  @Test func codesAreExactlyTheSpecTable() {
    #expect(ErrorCode.allCases.map(\.rawValue) == Self.table.map(\.0))
  }

  @Test(arguments: table)
  func exitCodeMatchesTheSpec(code: String, exit: Int32) throws {
    let errorCode = try #require(ErrorCode(rawValue: code))
    #expect(errorCode.exitCode == exit)
  }

  @Test func onlyHumanCodesSendNextToTheHuman() {
    let human = ErrorCode.allCases.filter { $0.nextBy == .human }.map(\.rawValue)
    #expect(human == ["human_only", "read_only_promoted", "env"])
  }

  // The "Agent should" column of the spec §16 table.
  static let agentShould: [Int32: String] = [
    1: "Read `silta <cmd> --help` and fix the call",
    2: "Check the ref, or carry on without silta",
    3:
      "Stop and ask the human in chat; for `human_only`, rerun with "
      + "`--approved \"<their words>\"` after they say yes",
    4: "Retry with `--app <slug>` from the candidates",
    5: "Retry once after a few seconds",
    6: "Re-read, then decide; don't steal",
    7: "Request a review or ask the human",
    8: "Wait for `retry_after_s`, or summarise",
    9: "Report the printed fix to the human",
  ]

  @Test(arguments: ErrorCode.allCases)
  func agentShouldMatchesTheSpec(code: ErrorCode) {
    #expect(code.agentShould == Self.agentShould[code.exitCode])
  }
}
