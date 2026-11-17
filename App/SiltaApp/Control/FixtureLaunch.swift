#if DEBUG
  import Foundation
  import SiltaAppSupport

  enum FixtureLaunch {
    nonisolated struct Configuration: Sendable {
      let home: URL
      let user: String
      let now: Date
    }

    static func parse(_ arguments: [String]) throws -> Bool {
      try ControlLaunch.parse(arguments) != nil
    }

    static func prepare() throws -> Configuration {
      let root = FileManager.default.temporaryDirectory
        .appending(path: "silta-mac-fixture-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      return Configuration(home: home, user: AppV2Fixture.user, now: AppV2Fixture.now)
    }
  }
#endif
