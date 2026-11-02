package import Foundation

/// Supplies UTC instants. Reading a clock may advance its deterministic state.
package protocol Clock: Sendable {
  /// Returns the next instant without waiting.
  func now() -> Date
}

/// Reads the host's wall clock.
package struct SystemClock: Clock {
  /// Creates a system-backed provider.
  package init() {}

  /// Returns the current host instant.
  package func now() -> Date {
    Date()  // guard:allow-nondeterminism the system clock is the time boundary
  }
}
