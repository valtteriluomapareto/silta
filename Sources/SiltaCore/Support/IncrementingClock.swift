package import Foundation
import Synchronization

/// A deterministic clock that returns `start` first, then advances 1 ms per read.
package final class IncrementingClock: Clock {
  private let start: Date
  private let reads = Mutex<UInt64>(0)

  package init(start: Date) { self.start = start }

  package func now() -> Date {
    reads.withLock { count in
      defer { count += 1 }
      return start.addingTimeInterval(Double(count) / 1000)
    }
  }
}
