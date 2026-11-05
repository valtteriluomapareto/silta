import Foundation
package import Testing

extension Tag {
  /// Integration and stress tests enabled only by the explicit slow-tier environment gate.
  @Tag package static var slow: Self
}

/// Whether this test process was explicitly asked to run stress and scenarios.
package func slowTestsEnabled() -> Bool {
  ProcessInfo.processInfo.environment["SILTA_SLOW_TESTS"] == "1"
}

extension Tag {
  /// Wall-clock deadline checks, enabled only by the isolated deadline-tier gate.
  @Tag package static var deadline: Self
}

/// Whether this test process runs the wall-clock deadline tier. Such a check can't tell
/// a slow process from a busy machine, so `scripts/verify.sh full` runs it serially and
/// alone, after the parallel suite.
package func deadlineTestsEnabled() -> Bool {
  ProcessInfo.processInfo.environment["SILTA_DEADLINE_TESTS"] == "1"
}
