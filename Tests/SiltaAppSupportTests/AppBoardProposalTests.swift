#if DEBUG
  @testable import SiltaAppSupport
  import SiltaTestSupport
  import Testing

  struct AppBoardProposalTests {
    @Test func proposalsStaySeparateFromOpenLanesAndCounts() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let board = try AppReaderTests.reader(scratch).snapshot(workspace: "acme").board
        #expect(Set(board.proposals.map(\.ref)) == ["AC-21", "AC-22", "AC-23"])
        #expect(board.proposals.allSatisfy { $0.status == "proposed" })
        #expect(board.proposedCount == board.proposals.count)
        #expect(board.todo.count + board.doing.count + board.review.count == 7)
        #expect(board.appOpenCounts.values.reduce(0, +) == 7)
      }
    }
  }
#endif
