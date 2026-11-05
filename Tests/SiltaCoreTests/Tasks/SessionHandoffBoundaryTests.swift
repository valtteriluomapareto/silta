import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

struct SessionHandoffBoundaryTests {
  @Test(arguments: [-1, 0, 1]) func handoffFreshnessHasAnExactTwoHourBoundary(offset: Int64)
    async throws
  {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let environment = try TaskServiceTests.environment(home, clock: clock)
      try TaskServiceTests.setup(environment)
      let tasks = TaskService(environment: environment)
      var draft = TaskDraft(title: "Acme work")
      draft.start = true
      _ = try await tasks.add(draft, directory: home)
      _ = try tasks.plan("AC-1", text: "- [ ] Acme next")
      clock.advance(milliseconds: 7_200_000 + offset)
      #expect(try SessionService(environment: environment).check().count == (offset < 0 ? 1 : 0))
    }
  }
}
