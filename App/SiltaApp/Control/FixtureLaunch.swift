#if DEBUG
  import Darwin
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

    static func prepare(runDirectory: URL? = nil) throws -> Configuration {
      let manager = FileManager.default
      let temporary = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
      let root: URL
      if let runDirectory {
        let canonical = runDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard runDirectory.path == canonical.path,
          canonical.deletingLastPathComponent().path == temporary.path,
          canonical.lastPathComponent.hasPrefix("silta-app-")
        else { throw refusedDirectory() }
        let attributes = try manager.attributesOfItem(atPath: canonical.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
          attributes[.ownerAccountID] as? UInt32 == getuid(),
          attributes[.posixPermissions] as? Int == 0o700,
          !manager.fileExists(atPath: canonical.appending(path: "state.json").path)
        else { throw refusedDirectory() }
        root = canonical
      } else {
        root = temporary.appending(path: "silta-mac-fixture-" + UUID().uuidString)
        try manager.createDirectory(
          at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      }
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      return Configuration(home: home, user: AppV2Fixture.user, now: AppV2Fixture.now)
    }

    private static func refusedDirectory() -> AppLoadFailure {
      AppLoadFailure(message: "Use the private temporary directory created by silta-app.sh launch.")
    }
  }
#endif
