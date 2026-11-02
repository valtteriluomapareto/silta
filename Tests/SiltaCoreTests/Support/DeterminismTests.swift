import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

struct DeterminismTests {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  @Test(arguments: [false, true]) func clockContract(fake: Bool) {
    let clock: any SiltaCore.Clock = fake ? FakeClock(now: start) : SystemClock()
    #expect(clock.now().timeIntervalSince1970.isFinite)
  }

  @Test func fakeClockCanAdvanceWithoutWaiting() {
    let clock = FakeClock(now: start)
    clock.advance(milliseconds: 1500)
    #expect(clock.now() == start.addingTimeInterval(1.5))
  }

  @Test func deterministicClockAdvancesOneMillisecondPerRead() {
    let clock = IncrementingClock(start: start)
    for index in 0..<100 {
      #expect(abs(clock.now().timeIntervalSince(start) - Double(index) / 1000) < 0.000001)
    }
  }

  @Test(arguments: [false, true]) func idContract(fake: Bool) throws {
    let ids: any IDGenerator = fake ? FakeIDGenerator(seed: 42) : SystemIDGenerator()
    let values = try (0..<1000).map { _ in try ids.next(at: start) }
    #expect(Set(values).count == values.count)
    #expect(values.allSatisfy { $0.wholeMatch(of: /[0-7][0-9A-HJKMNP-TV-Z]{25}/) != nil })
    #expect(values.allSatisfy { $0.hasPrefix("01HF7YAT00") })
  }

  @Test func seededIDsReplayAcrossInstancesAndEncodeBounds() throws {
    let first = SeededIDGenerator(seed: 0)
    let second = SeededIDGenerator(seed: 0)
    let third = SeededIDGenerator(seed: 1)
    let sequence = try (0..<20).map { _ in try first.next(at: start) }
    #expect(sequence == (try (0..<20).map { _ in try second.next(at: start) }))
    #expect(sequence.first != (try third.next(at: start)))
    #expect(try first.next(at: Date(timeIntervalSince1970: 0)).hasPrefix("0000000000"))
    let maximum = Date(timeIntervalSince1970: Double(0xFFFF_FFFF_FFFF as UInt64) / 1000)
    #expect(try first.next(at: maximum).hasPrefix("7ZZZZZZZZZ"))
    for seconds in [-1.0, .infinity, .nan, Double(0x1_0000_0000_0000 as UInt64) / 1000] {
      #expect(throws: (any Error).self) {
        try first.next(at: Date(timeIntervalSince1970: seconds))
      }
    }
  }

  @Test func defaultHomeAndRealHomeAliasesIgnoreOverrides() throws {
    try withScratchDirectory { scratch in
      let user = scratch.appending(path: "user")
      let realHome = user.appending(path: ".silta")
      try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
      let alias = scratch.appending(path: "alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realHome)
      for path in [nil, realHome.path, alias.path] {
        var environment = ["SILTA_NOW": "bad", "SILTA_ID_SEED": "bad"]
        environment["SILTA_HOME"] = path
        let env = try SiltaEnvironment.system(
          environment: environment, userHome: user, temporaryRoots: [scratch])
        #expect(env.clock is SystemClock)
        #expect(env.ids is SystemIDGenerator)
        #expect(env.home.url == realHome.resolvingSymlinksInPath())
      }
    }
  }

  @Test func temporaryHomeHonoursOverridesAndReplay() throws {
    try withScratchDirectory { scratch in
      let environment = [
        "SILTA_HOME": scratch.appending(path: "isolated").path,
        "SILTA_NOW": "2023-11-14T22:13:20.000Z", "SILTA_ID_SEED": "18446744073709551615",
      ]
      func make() throws -> SiltaEnvironment {
        try SiltaEnvironment.system(
          environment: environment, userHome: scratch.appending(path: "user"),
          temporaryRoots: [scratch])
      }
      let first = try make()
      let second = try make()
      #expect(first.clock.now() == start)
      #expect(abs(first.clock.now().timeIntervalSince(start) - 0.001) < 0.000001)
      #expect(try first.ids.next(at: start) == second.ids.next(at: start))
      #expect(!FileManager.default.fileExists(atPath: first.home.url.path))
    }
  }

  @Test func temporaryGateRejectsEscapesAndSiblingPrefixes() throws {
    try withScratchDirectory { scratch in
      let root = scratch.appending(path: "temp")
      let outside = scratch.appending(path: "persistent")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      let alias = root.appending(path: "escape")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
      for path in [root, outside, scratch.appending(path: "temp-sibling"), alias.appending(path: "new")] {
        let env = try SiltaEnvironment.system(
          environment: ["SILTA_HOME": path.path, "SILTA_NOW": "bad", "SILTA_ID_SEED": "bad"],
          userHome: scratch.appending(path: "user"), temporaryRoots: [root])
        #expect(env.clock is SystemClock)
        #expect(env.ids is SystemIDGenerator)
      }
    }
  }

  @Test(arguments: ["SILTA_NOW", "SILTA_ID_SEED"])
  func explicitModeRejectsMalformedOverrides(key: String) throws {
    try withScratchDirectory { scratch in
      for bad in ["", "bad", "-1", "18446744073709551616"] {
        #expect(throws: (any Error).self) {
          try SiltaEnvironment.system(
            environment: [key: bad], userHome: scratch, deterministic: true)
        }
      }
      let env = try SiltaEnvironment.system(
        environment: ["SILTA_NOW": "2023-11-14T22:13:20Z", "SILTA_ID_SEED": "0"],
        userHome: scratch, deterministic: true)
      #expect(env.clock.now() == start)
      #expect(env.ids is SeededIDGenerator)
      #expect(throws: (any Error).self) {
        try SiltaHome.resolve(environment: ["SILTA_HOME": "relative"], userHome: scratch)
      }
    }
  }
}
