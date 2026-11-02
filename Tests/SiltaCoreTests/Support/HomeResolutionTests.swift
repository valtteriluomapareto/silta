import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HomeResolutionTests {
  @Test func absentCaseAliasOfRealHomeIgnoresOverrides() async throws {
    try await withScratchDirectory { scratch in
      let env = try await SiltaEnvironment.system(
        environment: [
          "SILTA_HOME": scratch.appending(path: ".SILTA").path,
          "SILTA_NOW": "2023-11-14T22:13:20.000Z", "SILTA_ID_SEED": "0",
        ],
        userHome: scratch, temporaryRoots: [], deterministic: true)
      #expect(env.clock is SystemClock)
      #expect(env.ids is SystemIDGenerator)
    }
  }

  @Test(arguments: [false, true]) func validOverrideWorksBesideBrokenDefault(symlink: Bool) throws {
    try withScratchDirectory { scratch in
      let broken = scratch.appending(path: ".silta")
      if symlink {
        try FileManager.default.createSymbolicLink(
          at: broken, withDestinationURL: scratch.appending(path: "missing"))
      } else {
        try Data().write(to: broken)
      }
      let home = try SiltaHome.resolve(
        environment: ["SILTA_HOME": scratch.appending(path: "isolated").path],
        userHome: scratch, temporaryRoots: [])
      #expect(home.url.lastPathComponent == "isolated")
      #expect(throws: SeamError.invalidHome) {
        try SiltaHome.resolve(environment: ["SILTA_HOME": broken.path], userHome: scratch)
      }
    }
  }

  @Test func preEpochOverrideIsRejectedAtAssembly() async throws {
    try await withScratchDirectory { scratch in
      do {
        await #expect(throws: SeamError.invalidNow) {
          try await SiltaEnvironment.system(
            environment: [
              "SILTA_HOME": scratch.appending(path: "data").path,
              "SILTA_NOW": "1969-12-31T23:59:59.000Z",
            ],
            userHome: scratch, temporaryRoots: [], deterministic: true)
        }
      }
    }
  }

  @Test func resolverOwnsDefaultTemporaryRoots() throws {
    try withScratchDirectory { scratch in
      let home = try SiltaHome.resolve(
        environment: ["SILTA_HOME": scratch.appending(path: "data").path], userHome: scratch)
      #expect(home.permitsDeterminism)
      let root = FileManager.default.temporaryDirectory
      let sibling = root.deletingLastPathComponent().appending(
        path: root.lastPathComponent + "-sibling")
      let other = try SiltaHome.resolve(
        environment: ["SILTA_HOME": sibling.path], userHome: scratch)
      #expect(!other.permitsDeterminism)
    }
  }

}
