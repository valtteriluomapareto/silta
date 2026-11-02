package import Foundation
import Synchronization

/// A deterministic clock that returns `start` first, then advances 1 ms per read.
package final class IncrementingClock: Clock {
  private let start: Date
  private let reads = Mutex<UInt64>(0)

  /// Starts the sequence at the supplied instant.
  package init(start: Date) {
    self.start = start
  }

  /// Returns the next millisecond tick without waiting.
  package func now() -> Date {
    reads.withLock { count in
      defer { count += 1 }
      return start.addingTimeInterval(Double(count) / 1000)
    }
  }
  /// Advances the deterministic timeline without a wall-clock wait.
  package func wait(milliseconds: UInt64) {
    reads.withLock { $0 += milliseconds }
  }
}
