#if DEBUG
  import Foundation

  enum TestLaunchPolicy {
    static func hosted(environment: [String: String]) -> Bool {
      ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCInjectBundleInto"].contains {
        environment[$0] != nil
      }
    }

    static func validate(environment: [String: String], temporaryRoots: [URL])
      throws
    {
      guard hosted(environment: environment) || environment["SILTA_APP_TESTING"] != nil else {
        return
      }
      guard environment["SILTA_APP_TESTING"] == "1",
        let path = environment["SILTA_HOME"], path.hasPrefix("/")
      else { throw Refusal.unsafeHome }
      let home = URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
      guard
        temporaryRoots.contains(where: {
          home.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        })
      else { throw Refusal.unsafeHome }
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: home, isDirectory: &directory),
        directory.boolValue
      else {
        throw Refusal.unsafeHome
      }
    }

    private enum Refusal: Error { case unsafeHome }
  }
#endif
