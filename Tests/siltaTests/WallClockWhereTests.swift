import Foundation
import GRDB
import SiltaTestSupport
import Testing

/// Wall-clock proof that `where` reads past a locked location cache instead of waiting
/// on it. Like the other `WallClock…` suites it runs only in the isolated deadline tier.
@Suite(
  .tags(.deadline), .enabled(if: deadlineTestsEnabled()), .serialized, .blockingTestWork,
  .timeLimit(.minutes(1)))
struct WallClockWhereTests {
  let fixture = WhereCommandTests()

  @Test func lockedCacheDoesNotDelayWhere() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["checkout", "-q", "--detach", "api"], repo, scratch)
      let first = try fixture.run([], repo, scratch)
      let index = scratch.appending(path: "silta-home/index.db")
      try #require(FileManager.default.fileExists(atPath: index.path))
      let queue = try DatabaseQueue(path: index.path)
      try queue.writeWithoutTransaction { db in
        try db.execute(sql: "BEGIN EXCLUSIVE")
        defer { try? db.execute(sql: "ROLLBACK") }  // best-effort lock release
        let locked = try fixture.run([], repo, scratch, timeout: 3)
        #expect(locked.termination == .exit(0))
        #expect(locked.stdout == first.stdout)
      }
    }
  }
}
