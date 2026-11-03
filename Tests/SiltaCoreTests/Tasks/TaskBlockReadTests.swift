import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskBlockReadTests {
  @Test func readinessDroppedPromotionFiltersAndReadPurity() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let service = try TaskOrganizationTests.service(home, clock: clock)
      try await TaskBlockTests.add(service, count: 4, directory: home)
      _ = try service.block("AC-1", TaskBlockTests.input(["AC-2", "AC-3"]))
      _ = try service.block("AC-4", TaskBlockTests.input())
      #expect(try service.show("AC-4").waiting?.on.isEmpty == true)
      #expect(try service.show("AC-4").waiting?.ready == false)
      #expect(try service.show("AC-1").waiting?.ready == false)
      _ = try await service.close("AC-2", result: "Acme done", directory: home)
      #expect(try service.show("AC-1").waiting?.ready == false)
      _ = try await service.close("AC-3", result: "Acme done", directory: home)
      #expect(try service.show("AC-1").waiting?.ready == true)
      var filter = TaskFilter()
      filter.on = "task:AC-2"
      #expect(try service.list(filter).map(\.ref) == ["AC-1"])
      filter.status = "doing"
      #expect(try service.list(filter).isEmpty)
      filter.status = nil
      _ = try service.promote("AC-2", external: "ado:42")
      #expect(try service.show("AC-1").waiting?.ready == false)
      #expect(try service.list(filter).map(\.ref) == ["AC-1"])
      try service.environment.db.write { tx in
        try tx.database.execute(sql: "UPDATE task SET status='dropped' WHERE seq=3")
      }
      #expect(try service.show("AC-1").waiting?.dropped == ["task:AC-3"])
      filter.on = "AC-3"
      let before = try TaskOrganizationTests.counts(service)
      #expect(try service.list(filter).map(\.ref) == ["AC-1"])
      #expect(try service.show("AC-1", timeline: true).status == "blocked")
      #expect(try TaskOrganizationTests.counts(service) == before)
      filter.on = "bad"
      #expect(throws: TaskError.self) { _ = try service.list(filter) }
      _ = try service.unblock(["AC-1"])
      #expect(try service.show("AC-1").status == "todo")
    }
  }

  @Test func dayAndAgeBoundaries() async throws {
    let parse = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    let leap = try parse.parse("2024-02-28T23:59:59.000Z")
    #expect(try TaskFollowUp.day(nil, at: leap) == "2024-03-06")
    #expect(try TaskFollowUp.day("1d", at: leap) == "2024-02-29")
    #expect(try TaskFollowUp.day("2024-02-29", at: leap) == "2024-02-29")
    #expect(try TaskFollowUp.day("0d", at: leap) == "2024-02-28")
    #expect(try TaskFollowUp.day("2024-02-28", at: leap) == "2024-02-28")
    for value in [
      "2024-02-27", "2023-02-29", "2024-02-30", "2024-13-01", "2024-01-00",
      "0000-01-01", "2024-2-29", "-1d", "1D", "1.5d", "tomorrow", "999999999999999999999d",
      "9223372036854775807d", "4000000d", "2024-02-29T00:00:00Z",
    ] {
      #expect(throws: TaskError.self) { _ = try TaskFollowUp.day(value, at: leap) }
    }
    #expect(try TaskFollowUp.day("100000d", at: leap) == "2297-12-13")
    try await withScratchDirectory { home in
      let clock = FakeClock(now: leap)
      let service = try TaskOrganizationTests.service(home, clock: clock)
      try await TaskBlockTests.add(service, directory: home)
      _ = try service.block("AC-1", TaskBlockTests.input())
      clock.advance(milliseconds: 2000)
      #expect(try service.show("AC-1").waiting?.ageDays == 0)
      _ = try service.archive("AC-1", keep: true)
      clock.advance(milliseconds: 86_398_000)
      #expect(try service.show("AC-1").waiting?.ageDays == 1)
      clock.advance(milliseconds: -172_800_000)
      #expect(try service.show("AC-1").waiting?.ageDays == 0)
    }
  }

  @Test(arguments: [false, true]) func closeCleansOnlyBlockMetadata(drop: Bool) async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, directory: home)
      _ = try service.link("AC-1", target: "url:https://example.com")
      _ = try service.block("AC-1", TaskBlockTests.input(["ext:acme"]))
      try service.environment.db.write { tx in
        try tx.database.execute(sql: "ALTER TABLE task ADD COLUMN future TEXT DEFAULT 'default'")
        try tx.database.execute(
          sql: "UPDATE task SET future='Acme retained',acceptance_md='Acme acceptance'")
        try tx.database.execute(sql: "UPDATE workspace SET settings='{" + "\"future\":42}'")
      }
      _ = try await service.close("AC-1", result: "Acme closed", dropped: drop, directory: home)
      let task = try service.show("AC-1", timeline: true)
      #expect(task.status == (drop ? "dropped" : "done"))
      #expect(task.followUpAt == nil && task.waiting == nil)
      #expect(task.links.map(\.rel) == ["cites"] && task.acceptance == "Acme acceptance")
      #expect(task.timeline?.filter { $0.kind == "block" }.count == 1)
      try service.environment.db.read { (db: Database) throws in
        #expect(try String.fetchOne(db, sql: "SELECT future FROM task") == "Acme retained")
        #expect(try String.fetchOne(db, sql: "SELECT settings FROM workspace") == "{\"future\":42}")
      }
    }
  }
}
