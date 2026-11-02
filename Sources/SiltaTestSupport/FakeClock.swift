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
}
