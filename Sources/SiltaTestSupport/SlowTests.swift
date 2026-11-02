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
