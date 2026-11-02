package import Foundation
import SiltaCore
import Synchronization

/// A manually advanced clock. Reads never advance time or wait.
package final class FakeClock: SiltaCore.Clock {
  private let instant: Mutex<Date>

  package init(now: Date) { instant = Mutex(now) }
  package func now() -> Date { instant.withLock { $0 } }
  package func advance(milliseconds: Int64) {
    instant.withLock { $0.addTimeInterval(Double(milliseconds) / 1000) }
  }
}
