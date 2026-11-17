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
        temporaryRoots: [FileManager.default.temporaryDirectory, URL(filePath: "/private/tmp")],
        forbiddenHome: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".silta"))
    }

    @Test(arguments: [
      "missing-marker", "missing", "empty", "relative", "unexpanded", "outside", "alias",
    ])
    func unsafeTestHomesRefuseBeforeAnyReader(_ fault: String) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }  // scratch cleanup
      let allowed = root.appending(path: "fixture")
      let forbidden = root.appending(path: "forbidden")
      try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: forbidden, withIntermediateDirectories: true)
      let alias = root.appending(path: "alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: forbidden)
      var environment = [
        "SILTA_APP_TESTING": "1", "SILTA_HOME": allowed.path,
        "SILTA_APP_TEST_HOME": allowed.path, "XCTestConfigurationFilePath": "synthetic",
      ]
      switch fault {
      case "missing-marker": environment.removeValue(forKey: "SILTA_APP_TESTING")
      case "missing": environment.removeValue(forKey: "SILTA_HOME")
      case "empty": environment["SILTA_HOME"] = ""
      case "relative": environment["SILTA_HOME"] = "fixture"
      case "unexpanded": environment["SILTA_HOME"] = "$(SILTA_APP_TEST_HOME)"
      case "outside": environment["SILTA_HOME"] = "/Users/Acme/missing"
      default: environment["SILTA_HOME"] = alias.path
      }
      environment["SILTA_APP_TEST_HOME"] = environment["SILTA_HOME"]
      do {
        #expect(throws: (any Error).self) {
          try TestLaunchPolicy.validate(
            environment: environment,
            temporaryRoots: [root], forbiddenHome: forbidden)
        }
      }
    }

    @Test func ordinaryLaunchDoesNotRequireTestSettings() throws {
      try TestLaunchPolicy.validate(
        environment: [:], temporaryRoots: [],
        forbiddenHome: URL(filePath: "/Users/Acme/.silta"))
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
