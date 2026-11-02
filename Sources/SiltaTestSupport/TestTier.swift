import Foundation
package import Testing

extension Tag {
  /// Slow tests: stress and scenario runs. They run only in `scripts/verify.sh full`.
  @Tag package static var slow: Self
}

/// Which test tiers this run includes (coding guidelines §6).
package enum TestTier {
  /// True when `SILTA_SLOW_TESTS=1`, which `scripts/verify.sh full` sets. Slow tests use
  /// `.tags(.slow)` and `.enabled(if: TestTier.slowEnabled)`.
  package static var slowEnabled: Bool {
    ProcessInfo.processInfo.environment["SILTA_SLOW_TESTS"] == "1"
  }
}
