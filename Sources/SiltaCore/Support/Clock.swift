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

/// Parses a canonical UTC timestamp, `YYYY-MM-DDTHH:MM:SS.mmmZ`.
///
/// ISO 8601 parsing alone is lenient: it accepts offsets, short fractions and
/// out-of-range components. Formatting the instant back with `ISO8601DateFormatter`
/// rejects everything that is not byte-for-byte canonical, while its fractional
/// seconds survive the round trip. The returned instant comes from the format style
/// the rest of the core uses to format timestamps.
func utcInstant(_ raw: String) -> Date? {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
    return nil
  }
  do {
    return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw)
  } catch {
    return nil
  }
}
