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

  @Test func everyCodeSaysWhatTheAgentShouldDo() {
    for code in ErrorCode.allCases {
      #expect(!code.agentShould.isEmpty, "\(code.rawValue)")
    }
  }
}
