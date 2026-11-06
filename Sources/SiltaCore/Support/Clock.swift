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
package func utcDay(_ date: Date) -> String {
  String(date.formatted(.iso8601).prefix(10))
}

/// Formats an instant as a canonical UTC timestamp, `YYYY-MM-DDTHH:MM:SS.mmmZ`.
///
/// Rounds to the nearest millisecond before formatting. `Date.ISO8601FormatStyle`
/// truncates fractional seconds, which can write an accepted instant one
/// millisecond low.
func utcTimestamp(_ date: Date) -> String {
  let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
  let seconds = Int64((Double(milliseconds) / 1000).rounded(.down))
  let fraction = milliseconds - seconds * 1000
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  let whole = formatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
  return String(whole.dropLast()) + String(format: ".%03lldZ", fraction)
}

/// Parses a canonical UTC timestamp, `YYYY-MM-DDTHH:MM:SS.mmmZ`.
///
/// ISO 8601 parsing alone is lenient: it accepts offsets, short fractions and
/// out-of-range components. A canonical timestamp is one that `utcTimestamp`
/// writes back byte for byte.
package func utcInstant(_ raw: String) -> Date? {
  do {
    let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw)
    return utcTimestamp(date) == raw ? date : nil
  } catch {
    return nil
  }
}
