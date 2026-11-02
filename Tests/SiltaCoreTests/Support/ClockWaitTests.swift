import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

struct ClockWaitTests {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func waitingAdvancesFakeAndDeterministicClocks() {
    let fake = FakeClock(now: start)
    fake.wait(milliseconds: 17)
    #expect(abs(fake.now().timeIntervalSince(start) - 0.017) < 0.000001)
    let deterministic = IncrementingClock(start: start)
    deterministic.wait(milliseconds: 17)
    #expect(abs(deterministic.now().timeIntervalSince(start) - 0.017) < 0.000001)
    #expect(abs(deterministic.now().timeIntervalSince(start) - 0.018) < 0.000001)
    let system: any SiltaCore.Clock = SystemClock()
    system.wait(milliseconds: 0)
    #expect(system.now().timeIntervalSince1970.isFinite)
  }

}
