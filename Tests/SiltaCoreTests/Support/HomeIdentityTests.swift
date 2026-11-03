import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HomeIdentityTests {
  @Test func caseAliasesCannotEnableRealHomeOverrides() async throws {
    try await withScratchDirectory { scratch in
      let real = scratch.appending(path: ".silta")
      try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
      let variant = scratch.appending(path: ".SILTA")
      let env = try await SiltaEnvironment.system(
        environment: ["SILTA_HOME": variant.path, "SILTA_NOW": "2023-11-14T22:13:20.123Z"],
        userHome: scratch, temporaryRoots: [], deterministic: true)
      #expect(!env.home.permitsDeterminism)
      #expect(env.clock is SystemClock)
    }
  }

  // realpath leaves the Data-volume firmlink path as it is, though it names the same files.
  @Test(arguments: [true, false])
  func firmlinkAliasCannotEnableRealHomeOverrides(exists: Bool) throws {
    try withScratchDirectory { scratch in
      let real = scratch.appending(path: ".silta")
      if exists {
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
      }
      let alias = URL(filePath: "/System/Volumes/Data" + real.path)
      try #require(FileManager.default.fileExists(atPath: "/System/Volumes/Data" + scratch.path))
      let home = try SiltaHome.resolve(
        environment: ["SILTA_HOME": alias.path], userHome: scratch, temporaryRoots: [],
        deterministic: true)
      #expect(!home.permitsDeterminism)
    }
  }

  // A dangling ~/.silta symlink names where the real home will be created.
  @Test func danglingDefaultHomeTargetCannotEnableOverrides() throws {
    try withScratchDirectory { scratch in
      let target = scratch.appending(path: "acme-data")
      try FileManager.default.createSymbolicLink(
        at: scratch.appending(path: ".silta"), withDestinationURL: target)
      let home = try SiltaHome.resolve(
        environment: ["SILTA_HOME": target.path], userHome: scratch, deterministic: true)
      #expect(!home.permitsDeterminism)
    }
  }
}
