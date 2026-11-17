#if DEBUG
  import Darwin
  import Foundation
  import Testing

  @MainActor enum AppTestCLI {
    static func run(_ arguments: [String], home: URL, seed: Int = 151) throws {
      let path = try #require(ProcessInfo.processInfo.environment["SILTA_APP_TEST_CLI"])
      let process = Process()
      process.executableURL = URL(filePath: path)
      process.arguments = arguments
      let user = home.deletingLastPathComponent().appending(path: "user")
      try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
      process.environment = [
        "HOME": user.path, "SILTA_HOME": home.path,
        "USER": "acme", "SILTA_ACTOR": "agent:codex:app-tests", "PATH": "/usr/bin:/bin",
        "SILTA_NOW": "2026-11-16T12:00:00.000Z", "SILTA_ID_SEED": String(seed),
      ]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      let finished = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in finished.signal() }
      try process.run()
      if finished.wait(timeout: .now() + 10) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
      }
      process.waitUntilExit()
      try #require(process.terminationReason == .exit && process.terminationStatus == 0)
    }
  }
#endif
