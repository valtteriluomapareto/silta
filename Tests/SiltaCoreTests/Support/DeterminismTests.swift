import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
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
    let ids: any IDGenerator = fake ? SeededIDGenerator(seed: 42) : SystemIDGenerator()
    let values = try (0..<1000).map { _ in try ids.next(at: start) }
    #expect(Set(values).count == values.count)
    #expect(values.allSatisfy { $0.wholeMatch(of: /[0-7][0-9A-HJKMNP-TV-Z]{25}/) != nil })
    #expect(values.allSatisfy { $0.hasPrefix("01HF7YAT00") })
    #expect(try ids.next(at: Date(timeIntervalSince1970: 0)).hasPrefix("0000000000"))
    let maximum = Date(timeIntervalSince1970: Double(0xFFFF_FFFF_FFFF as UInt64) / 1000)
    #expect(try ids.next(at: maximum).hasPrefix("7ZZZZZZZZZ"))
    for seconds in [-1.0, -0.0001, .infinity, .nan, Double(0x1_0000_0000_0000 as UInt64) / 1000] {
      #expect(throws: SeamError.invalidTimestamp) {
        try ids.next(at: Date(timeIntervalSince1970: seconds))
      }
    }
  }

  @Test func seededIDsReplayAcrossInstancesAndEncodeBounds() throws {
    #expect(
      try SeededIDGenerator(seed: 0).next(at: Date(timeIntervalSince1970: 0))
        == "0000000000NZ6HTYSSN0GE5X35")
    let first = SeededIDGenerator(seed: 0)
    let second = SeededIDGenerator(seed: 0)
    let third = SeededIDGenerator(seed: 1)
    let sequence = try (0..<20).map { _ in try first.next(at: start) }
    #expect(sequence == (try (0..<20).map { _ in try second.next(at: start) }))
    #expect(sequence.first != (try third.next(at: start)))
  }

  @Test func defaultHomeAndRealHomeAliasesIgnoreOverrides() async throws {
    try await withScratchDirectory { scratch in
      let user = scratch.appending(path: "user")
      let realHome = user.appending(path: ".silta")
      try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
      let alias = scratch.appending(path: "alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realHome)
      for path in [nil, realHome.path, alias.path] {
        var environment = ["SILTA_NOW": "bad", "SILTA_ID_SEED": "bad"]
        environment["SILTA_HOME"] = path
        let env = try await SiltaEnvironment.system(
          environment: environment, userHome: user, temporaryRoots: [scratch])
        #expect(env.clock is SystemClock)
        #expect(env.ids is SystemIDGenerator)
        #expect(env.home.url.path == realHome.path)
      }
    }
  }

  @Test func temporaryHomeHonoursOverridesAndReplay() async throws {
    try await withScratchDirectory { scratch in
      let environment = [
        "SILTA_HOME": scratch.appending(path: "isolated").path,
        "SILTA_NOW": "2023-11-14T22:13:20.000Z", "SILTA_ID_SEED": "18446744073709551615",
      ]
      func make() async throws -> SiltaEnvironment {
        try await SiltaEnvironment.system(
          environment: environment, userHome: scratch.appending(path: "user"),
          temporaryRoots: [scratch])
      }
      let first = try await make()
      let second = try await make()
      try #require(first.clock is IncrementingClock)
      #expect(first.clock.now() == start)
      #expect(abs(first.clock.now().timeIntervalSince(start) - 0.001) < 0.000001)
      let expected = try SeededIDGenerator(seed: .max).next(at: start)
      #expect(try first.ids.next(at: start) == expected)
      #expect(try second.ids.next(at: start) == expected)
      #expect(!FileManager.default.fileExists(atPath: first.home.url.path))
    }
  }

  @Test func temporaryGateRejectsEscapesAndSiblingPrefixes() async throws {
    try await withScratchDirectory { scratch in
      let root = scratch.appending(path: "temp")
      let outside = scratch.appending(path: "persistent")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      let alias = root.appending(path: "escape")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
      for path in [
        root, outside, scratch.appending(path: "temp-sibling"), alias.appending(path: "new"),
      ] {
        let env = try await SiltaEnvironment.system(
          environment: ["SILTA_HOME": path.path, "SILTA_NOW": "bad", "SILTA_ID_SEED": "bad"],
          userHome: scratch.appending(path: "user"), temporaryRoots: [root])
        #expect(env.clock is SystemClock)
        #expect(env.ids is SystemIDGenerator)
      }
    }
  }

  @Test(arguments: ["SILTA_NOW", "SILTA_ID_SEED"])
  func explicitModeRejectsMalformedOverrides(key: String) async throws {
    try await withScratchDirectory { scratch in
      for bad in ["", "bad", "-1", "18446744073709551616"] {
        await #expect(throws: (any Error).self) {
          try await SiltaEnvironment.system(
            environment: [key: bad, "SILTA_HOME": scratch.appending(path: "data").path],
            userHome: scratch, temporaryRoots: [], deterministic: true)
        }
      }
      let env = try await SiltaEnvironment.system(
        environment: [
          "SILTA_HOME": scratch.appending(path: "data").path,
          "SILTA_NOW": "2023-11-14T22:13:20.000Z", "SILTA_ID_SEED": "0",
        ],
        userHome: scratch, temporaryRoots: [], deterministic: true)
      #expect(env.clock.now() == start)
      #expect(env.ids is SeededIDGenerator)
      #expect(throws: (any Error).self) {
        try SiltaHome.resolve(environment: ["SILTA_HOME": "relative"], userHome: scratch)
      }
    }
  }
  @Test func danglingHomeSymlinkAndMalformedInstantAreRejected() async throws {
    try await withScratchDirectory { scratch in
      let alias = scratch.appending(path: "dangling")
      try FileManager.default.createSymbolicLink(
        at: alias, withDestinationURL: scratch.appending(path: "missing"))
      #expect(throws: (any Error).self) {
        try SiltaHome.resolve(
          environment: ["SILTA_HOME": alias.appending(path: "child").path],
          userHome: scratch)
      }
      for raw in ["2023-11-14T22:13:20Zjunk", "2023-02-30T22:13:20Z", "2023-11-14"] {
        await #expect(throws: (any Error).self) {
          try await SiltaEnvironment.system(
            environment: ["SILTA_HOME": scratch.appending(path: "data").path, "SILTA_NOW": raw],
            userHome: scratch, temporaryRoots: [], deterministic: true)
        }
      }
    }
  }

  @Test func missingTemporaryComponentsCannotHideAnEscape() throws {
    try withScratchDirectory { scratch in
      let root = scratch.appending(path: "temp")
      let user = scratch.appending(path: "user")
      let realHome = user.appending(path: ".silta")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
      let alias = root.appending(path: "alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realHome)
      for path in [
        root.path + "/missing/../../user/.silta",
        root.path + "/missing/../alias/new",
      ] {
        #expect(throws: (any Error).self) {
          try SiltaHome.resolve(
            environment: ["SILTA_HOME": path],
            userHome: user, temporaryRoots: [root])
        }
      }
    }
  }

  @Test func ulidTimestampsPreserveClockMillisecondTicks() throws {
    for initial in [start, start.addingTimeInterval(0.0006)] {
      let clock = IncrementingClock(start: initial)
      let ids = SeededIDGenerator(seed: 0)
      let base = UInt64((initial.timeIntervalSince1970 * 1000).rounded())
      let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
      for index in 0..<100 {
        let id = try ids.next(at: clock.now())
        let decoded = try id.prefix(10).reduce(UInt64(0)) { value, character in
          let digit = try #require(alphabet.firstIndex(of: character))
          return value * 32 + UInt64(digit)
        }
        #expect(decoded == base + UInt64(index))
      }
    }
    #expect(
      try SeededIDGenerator(seed: 0).next(at: Date(timeIntervalSince1970: 0.0004))
        .hasPrefix("0000000000"))
    #expect(
      try SeededIDGenerator(seed: 0).next(at: Date(timeIntervalSince1970: 0.0006))
        .hasPrefix("0000000001"))
  }

  @Test func explicitModeCannotEnableOverridesAtTheRealHome() async throws {
    try await withScratchDirectory { scratch in
      let user = scratch.appending(path: "user")
      let real = user.appending(path: ".silta")
      try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
      let alias = scratch.appending(path: "alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
      do {
        for path in [nil, real.path, alias.path] {
          var values = ["SILTA_NOW": "2023-11-14T22:13:20.123Z", "SILTA_ID_SEED": "0"]
          values["SILTA_HOME"] = path
          let env = try await SiltaEnvironment.system(
            environment: values, userHome: user, temporaryRoots: [],
            deterministic: true)
          #expect(env.clock is SystemClock)
          #expect(env.ids is SystemIDGenerator)
        }
      }
    }
  }

  @Test func defaultTemporaryRootsAreUsedWithoutInjection() async throws {
    try await withScratchDirectory { scratch in
      let home = scratch.appending(path: "isolated")
      let user = scratch.appending(path: "user")
      let env = try await SiltaEnvironment.system(
        environment: [
          "SILTA_HOME": home.path,
          "SILTA_NOW": "2023-11-14T22:13:20.123Z",
        ], userHome: user)
      try #require(env.clock is IncrementingClock)
      let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
      #expect(env.clock.now().formatted(format) == "2023-11-14T22:13:20.123Z")
      #expect(env.clock.now().formatted(format) == "2023-11-14T22:13:20.124Z")
      let root = FileManager.default.temporaryDirectory
      let sibling = root.deletingLastPathComponent().appending(
        path: root.lastPathComponent + "-sibling")
      let other = try await SiltaEnvironment.system(
        environment: [
          "SILTA_HOME": sibling.path,
          "SILTA_NOW": "2023-11-14T22:13:20.123Z",
        ], userHome: user)
      #expect(other.clock is SystemClock)
    }
  }

  @Test func nonCanonicalUTCOverridesAreRejected() async throws {
    try await withScratchDirectory { scratch in
      do {
        for raw in [
          "2023-11-14T22:13:20Z", "2023-11-14T22:13:20.123+02:00",
          "2023-11-14T22:13:20.123+00:00", "2023-11-14T22:13:20.1234Z",
        ] {
          await #expect(throws: (any Error).self) {
            try await SiltaEnvironment.system(
              environment: [
                "SILTA_HOME": scratch.appending(path: "data").path,
                "SILTA_NOW": raw,
              ], userHome: scratch, temporaryRoots: [], deterministic: true)
          }
        }
      }
    }
  }

}

extension DeterminismTests {
  @Test(arguments: ["2023-11-14T22:13:20.859Z", "2023-11-14T22:13:20.426Z"])
  func canonicalMillisecondNowIsAccepted(raw: String) async throws {
    try await withScratchDirectory { scratch in
      let env = try await SiltaEnvironment.system(
        environment: [
          "SILTA_HOME": scratch.appending(path: "data").path,
          "SILTA_NOW": raw,
        ], userHome: scratch, temporaryRoots: [], deterministic: true)
      let next = try nextMillisecond(raw)
      #expect(utcTimestamp(env.clock.now()) == raw)
      #expect(utcTimestamp(env.clock.now()) == next)
    }
  }

  private func nextMillisecond(_ raw: String) throws -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw)
    return formatter.string(from: date.addingTimeInterval(0.001))
  }

}
