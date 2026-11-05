package import Foundation
import SiltaCore
import Synchronization

/// A manually advanced clock. Reads never advance time or wait.
package final class FakeClock: SiltaCore.Clock {
  private let instant: Mutex<Date>

  /// Fixes the initial instant.
  package init(now: Date) {
    instant = Mutex(now)
  }
  /// Returns the current instant without advancing it.
  package func now() -> Date {
    instant.withLock { $0 }
  }
  /// Moves the instant by a signed millisecond count, without waiting.
  package func advance(milliseconds: Int64) {
    instant.withLock { $0.addTimeInterval(Double(milliseconds) / 1000) }
  }
  /// Advances the fake instant by the requested retry delay without waiting.
  package func wait(milliseconds: UInt64) {
    instant.withLock { $0.addTimeInterval(Double(milliseconds) / 1000) }
  }
}

/// Monotonic elapsed time that only the test advances, for deadline decisions.
package final class FakeElapsed: Sendable {
  private let value: Mutex<Duration>

  /// Fixes the initial elapsed time.
  package init(milliseconds: Int) {
    value = Mutex(.milliseconds(milliseconds))
  }
  /// Returns the elapsed time without advancing it.
  package func now() -> Duration {
    value.withLock { $0 }
  }
}
