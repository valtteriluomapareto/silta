#if DEBUG
  import Darwin
  import Foundation
  import SiltaAppSupport
  @testable import SiltaApp
  import Testing

  @Suite(.timeLimit(.minutes(1)))
  @MainActor
  struct AppStartupTests {
    @Test func actualHostHasAnIsolatedHomeBeforeStartup() throws {
      #expect(AppV2Fixture.user == "acme")
      let environment = ProcessInfo.processInfo.environment
      #expect(environment["SILTA_APP_TESTING"] == "1")
      let path = try #require(environment["SILTA_HOME"])
      #expect(path == environment["SILTA_APP_TEST_HOME"])
      #expect(path.hasPrefix("/"))
      #expect(FileManager.default.fileExists(atPath: path))
      do {
        let recognized = TestLaunchPolicy.hosted(environment: environment)
        #expect(recognized)
      }
      try TestLaunchPolicy.validate(
        environment: environment,
        temporaryRoots: [FileManager.default.temporaryDirectory, URL(filePath: "/private/tmp")])
    }

    @Test(arguments: ["marker", "relative", "outside", "directory"])
    func unsafeTestHomesRefuseBeforeAnyReader(_ fault: String) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let allowed = root.appending(path: "fixture")
      try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
      var environment = [
        "SILTA_APP_TESTING": "1", "SILTA_HOME": allowed.path,
        "XCTestConfigurationFilePath": "synthetic",
      ]
      switch fault {
      case "marker": environment.removeValue(forKey: "SILTA_APP_TESTING")
      case "relative": environment["SILTA_HOME"] = "fixture"
      case "outside":
        let alias = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(
          at: alias, withDestinationURL: root.deletingLastPathComponent())
        environment["SILTA_HOME"] = alias.path
      default: environment["SILTA_HOME"] = root.appending(path: "missing").path
      }
      #expect(throws: (any Error).self) {
        try TestLaunchPolicy.validate(environment: environment, temporaryRoots: [root])
      }
    }

    @Test func fixtureLaunchAcceptsOnlyItsNamedDebugOption() throws {
      #expect(try FixtureLaunch.parse(["SiltaApp", "-SiltaFixture", "v2"]))
      #expect(
        try !FixtureLaunch.parse([
          "SiltaApp", "-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState", "YES",
          "-AppleLanguages", "(en)", "unrelated",
        ]))
      for arguments in [
        ["-SiltaUnknown"], ["-SiltaFixture"], ["-SiltaFixture", "other"],
        ["-SiltaFixture", "v2", "-SiltaOther"],
      ] {
        #expect(throws: AppLoadFailure.self) { try FixtureLaunch.parse(arguments) }
      }
    }

    @Test func fixtureLaunchCreatesFreshPrivateHomes() throws {
      let first = try FixtureLaunch.prepare()
      defer {
        try? FileManager.default.removeItem(at: first.home.deletingLastPathComponent())  // cleanup
      }
      let second = try FixtureLaunch.prepare()
      defer {
        try? FileManager.default.removeItem(at: second.home.deletingLastPathComponent())  // cleanup
      }
      #expect(first.home != second.home)
      #expect(first.now == AppV2Fixture.now && first.user == "acme")
      let reader = try AppReader(home: first.home, user: first.user, now: { AppV2Fixture.now })
      #expect(try reader.snapshot(workspace: "acme").work.waitingCount == 5)
      let permissions =
        try FileManager.default.attributesOfItem(
          atPath: first.home.deletingLastPathComponent().path)[.posixPermissions] as? Int
      #expect(permissions == 0o700)
    }

    @Test func ordinaryLaunchDoesNotRequireTestSettings() throws {
      try TestLaunchPolicy.validate(
        environment: [:], temporaryRoots: [])
    }

    @Test func invalidChildLaunchExitsBeforeOpeningAWindow() throws {
      let process = Process()
      process.executableURL = Bundle.main.executableURL
      process.environment = [
        "SILTA_APP_TESTING": "1", "SILTA_HOME": "relative",
        "SILTA_APP_TEST_HOME": "relative", "PATH": "/usr/bin:/bin", "USER": "acme",
        "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "/private/tmp",
        "CFFIXED_USER_HOME": ProcessInfo.processInfo.environment["HOME"] ?? "/private/tmp",
      ]
      let error = Pipe()
      process.standardError = error
      process.standardOutput = FileHandle.nullDevice
      let finished = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in finished.signal() }
      try process.run()
      if finished.wait(timeout: .now() + 5) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
      }
      process.waitUntilExit()
      let bytes = error.fileHandleForReading.readDataToEndOfFile()
      let diagnostic = try #require(String(data: bytes, encoding: .utf8))
      do {
        #expect(process.terminationReason == .exit && process.terminationStatus == 64)
        #expect(diagnostic.contains("Silta test launch refused"))
      }
    }
  }
#endif
