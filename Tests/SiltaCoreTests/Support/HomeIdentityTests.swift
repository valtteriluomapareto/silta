import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HomeIdentityTests {
  @Test func caseAliasesCannotEnableRealHomeOverrides() throws {
    try withScratchDirectory { scratch in
      let real = scratch.appending(path: ".silta")
      try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
      let variant = scratch.appending(path: ".SILTA")
      let env = try SiltaEnvironment.system(
        environment: ["SILTA_HOME": variant.path, "SILTA_NOW": "2023-11-14T22:13:20.123Z"],
        userHome: scratch, temporaryRoots: [], deterministic: true)
      #expect(!env.home.permitsDeterminism)
      #expect(env.clock is SystemClock)
    }
  }
}
