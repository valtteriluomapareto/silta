import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskBlockTests {
  static func add(_ service: TaskService, count: Int = 1, directory: URL) async throws {
    for _ in 0..<count {
      _ = try await TaskOrganizationTests.add(service, start: true, directory: directory)
    }
  }

  static func input(_ on: [String] = [], why: String = "Acme answer") -> TaskBlock {
    var input = TaskBlock(why: why)
    input.on = on
    return input
  }

  @Test func unionHistoryAgeAndAtomicUnblock() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let service = try TaskOrganizationTests.service(home, clock: clock)
      try await Self.add(service, count: 3, directory: home)
      _ = try service.link("AC-1", target: "topic:release", relation: "about")
      let first = try service.block("AC-1", Self.input(["AC-2", "task:AC-2", "ext:acme"]))
      #expect(first.status == "blocked" && first.followUpAt == "2023-11-21")
      #expect(first.waiting?.on == ["ext:acme", "task:AC-2"])
      #expect(first.waiting?.ready == false && first.waiting?.ageDays == 0)
      #expect(first.warnings.map(\.code) == ["new_party"])
      #expect(try service.show("AC-1").claimedBy == nil)
      #expect(try service.show("AC-1").claimedAt == nil)
      clock.advance(milliseconds: 2 * 86400 * 1000)
      var next = Self.input(["url:https://example.com/acme", "ext:acme"], why: "Acme revised")
      next.followUp = "0d"
      let second = try service.block("AC-1", next)
      #expect(second.followUpAt == "2023-11-16" && second.waiting?.ageDays == 2)
      #expect(second.waiting?.why == "Acme revised" && second.warnings.isEmpty)
      #expect(second.waiting?.on == ["ext:acme", "task:AC-2", "url:https://example.com/acme"])
      try Self.checkEvents(service)
      let before = try TaskOrganizationTests.counts(service)
      do {
        _ = try service.unblock(["AC-1", "AC-404"])
        Issue.record("Bad final reference accepted")
      } catch let error as TaskReferenceError {
        #expect(error.code == .notFound && error.message.contains("AC-404"))
      }
      #expect(throws: TaskError.self) { _ = try service.unblock(["AC-1", "AC-3"]) }
      #expect(try TaskOrganizationTests.counts(service) == before)
      #expect(try service.show("AC-1").status == "blocked")
      _ = try service.block("AC-3", Self.input())
      let results = try service.unblock(["AC-1", "task:AC-1", "AC-3"], why: "Acme answered")
      #expect(results.map(\.ref) == ["AC-1", "AC-3"] && results.map(\.status) == ["todo", "todo"])
      let cleared = try service.show("AC-1", timeline: true)
      #expect(cleared.followUpAt == nil && cleared.waiting == nil)
      #expect(cleared.links.map(\.rel) == ["about"])
      #expect(cleared.timeline?.filter { $0.kind == "unblock" }.map(\.body) == ["Acme answered"])
      clock.advance(milliseconds: 1000)
      #expect(try service.block("AC-1", Self.input(["ext:acme"])).waiting?.ageDays == 0)
      #expect(try service.block("AC-1", Self.input(["ext:acme"])).warnings.isEmpty)
    }
  }

  static func checkEvents(_ service: TaskService) throws {
    try service.environment.db.read { db in
      let events = try String.fetchAll(
        db, sql: "SELECT body FROM task_event WHERE kind='block' ORDER BY id")
      let bodies = try events.map { try TaskBlockEvent.decode($0) }
      #expect(bodies.count == 2 && bodies[0].why == "Acme answer")
      #expect(bodies[1].on.count == 3 && bodies[1].on.contains("ext:acme"))
      let uid = try String.fetchOne(db, sql: "SELECT uid FROM task WHERE seq=2")
      #expect(bodies[0].on.contains(try #require(uid)))
      #expect(!bodies[0].on.contains("task:AC-2"))
      let json = try JSONSerialization.jsonObject(with: Data(events[1].utf8)) as? [String: Any]
      #expect(Set(json?.keys.map { $0 } ?? []) == ["on", "follow_up", "why"])
    }
  }

  @Test(arguments: [
    "", "ext:", "ext:-acme", "ext:acme-", "ext:Acme", "ext:a_b", "ext:a.b",
    "ext:" + String(repeating: "a", count: 65), "url:ftp://example.com", "url:https://",
    "url:https://acme@example.com", "doc:acme", "app:platform", "plan#L1", "AC-1", "task:AC-2/1",
    "AC-02", "ZZ-2", "AC-404",
  ])
  func invalidTargetsRollBack(target: String) async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await Self.add(service, count: 2, directory: home)
      let before = try TaskOrganizationTests.counts(service)
      #expect(throws: TaskError.self) {
        _ = try service.block("AC-1", Self.input(["ext:acme", target]))
      }
      #expect(try TaskOrganizationTests.counts(service) == before)
      #expect(try service.show("AC-1").status == "doing")
      #expect(try service.show("AC-1").followUpAt == nil)
    }
  }

  @Test func grammarCyclesStatesAndReasons() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await Self.add(service, count: 5, directory: home)
      let party = "ext:" + String(repeating: "a", count: 64)
      let tokenLikeParty = "ext:" + String(repeating: "a", count: 52)
      let blocked = try service.block(
        "AC-1", Self.input([party, tokenLikeParty, "ext:a", "ext:a-1", "AC-2"]))
      #expect(blocked.waiting?.on.contains(party) == true)
      #expect(blocked.waiting?.on.contains(tokenLikeParty) == true)
      #expect(blocked.waiting?.on.contains("ext:a") == true)
      #expect(blocked.waiting?.on.contains("ext:a-1") == true)
      #expect(try service.block("AC-2", Self.input(["AC-1"])).status == "blocked")
      _ = try service.submit("AC-3")
      #expect(try service.block("AC-3", Self.input()).waiting?.ready == false)
      _ = try service.unblock(["AC-3"])
      #expect(try service.block("AC-3", Self.input()).status == "blocked")
      _ = try await service.close("AC-4", result: "Acme done", directory: home)
      _ = try await service.close("AC-5", result: "Acme dropped", dropped: true, directory: home)
      for ref in ["AC-4", "AC-5"] {
        #expect(throws: TaskError.self) { _ = try service.block(ref, Self.input()) }
        #expect(throws: TaskError.self) { _ = try service.block("AC-1", Self.input([ref])) }
      }
      _ = try await TaskOrganizationTests.add(service, directory: home)
      #expect(throws: TaskError.self) { _ = try service.block("AC-6", Self.input()) }
      #expect(try service.block("AC-1", Self.input(["AC-6"])).status == "blocked")
      #expect(throws: TaskError.self) { _ = try service.block("AC-1", Self.input(why: " \n ")) }
      #expect(throws: TaskError.self) { _ = try service.unblock([]) }
    }
  }
}
