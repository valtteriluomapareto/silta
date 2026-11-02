package import SiltaCore
import Synchronization

/// Captures ordered log entries without writing files or streams.
package final class FakeLog: Log {
  private let captured = Mutex<[LogEntry]>([])

  package init() {}
  package var entries: [LogEntry] { captured.withLock { $0 } }
  package func record(_ entry: LogEntry) { captured.withLock { $0.append(entry) } }
}
