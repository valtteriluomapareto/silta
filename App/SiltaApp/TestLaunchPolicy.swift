#if DEBUG
  import Foundation

  enum TestLaunchPolicy {
    static func hosted(environment: [String: String]) -> Bool { false }
    static func validate(environment: [String: String], temporaryRoots: [URL], forbiddenHome: URL) throws {}
  }
#endif
