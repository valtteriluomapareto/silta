#if DEBUG
  import Foundation
  import SiltaAppSupport

  enum FixtureLaunch {
    struct Configuration {
      let home: URL
      let user: String
      let now: Date
    }

    static func parse(_ arguments: [String]) throws -> Bool {
      let controls = arguments.enumerated().filter { $0.element.hasPrefix("-Silta") }
      guard !controls.isEmpty else { return false }
      guard controls.count == 1, let option = controls.first,
        option.element == "-SiltaFixture", arguments.indices.contains(option.offset + 1),
        arguments[option.offset + 1] == "v2"
      else {
        throw AppLoadFailure(message: "Use -SiltaFixture v2 for an isolated Debug fixture.")
      }
      return true
    }

    static func prepare() throws -> Configuration {
      let root = FileManager.default.temporaryDirectory
        .appending(path: "silta-mac-fixture-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      return Configuration(home: home, user: AppV2Fixture.user, now: AppV2Fixture.now)
    }
  }
#endif
