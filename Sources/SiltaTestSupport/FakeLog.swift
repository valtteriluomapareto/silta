package import SiltaCore
import Synchronization

/// Captures ordered log entries without writing files or streams.
package final class FakeLog: Log {
  private let captured = Mutex<[LogEntry]>([])

  /// Starts an empty log capture.
  package init() {}
  /// Entries in recording order.
  package var entries: [LogEntry] {
    captured.withLock { $0 }
  }
  /// Captures the entry without performing I/O.
  package func record(_ entry: LogEntry) {
    captured.withLock { $0.append(entry) }
  }
}
