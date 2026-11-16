#if DEBUG
  package import Foundation
  import SiltaAppSupport

  /// The shared viewer seed in the subprocess runner's standard scratch layout.
  package enum AppFixtures {
    /// Creates the task-only Acme viewer fixture without using the real data home.
    package static func seed(in scratch: URL) throws {
      try AppV2Fixture.seed(home: scratch.appending(path: "silta-home"))
    }
  }
#endif
