package import Foundation

/// Supplies UTC instants. Reading a clock may advance its deterministic state.
package protocol Clock: Sendable {
  /// Returns the next instant without waiting.
  func now() -> Date
  /// Waits for retry spacing; deterministic implementations advance without waiting.
  func wait(milliseconds: UInt64)
}

/// Reads the host's wall clock.
package struct SystemClock: Clock {
  /// Creates a system-backed provider.
  package init() {}

  /// Returns the current host instant.
  package func now() -> Date {
    Date()  // guard:allow-nondeterminism the system clock is the time boundary
  }

  /// Waits on the host clock for a bounded retry delay.
  package func wait(milliseconds: UInt64) {
    Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
  }
}

/// The UTC calendar day of an instant, as `YYYY-MM-DD`. Names daily logs and backups.
func utcDay(_ date: Date) -> String {
  String(date.formatted(.iso8601).prefix(10))
}
