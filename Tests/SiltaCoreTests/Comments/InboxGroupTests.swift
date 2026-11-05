import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct InboxGroupTests {
  static func add(_ service: TaskService, _ home: URL, _ title: String = "Acme work") async throws
    -> String
  {
    try await service.add(TaskDraft(title: title), directory: home).ref
  }

  static func block(_ service: TaskService, _ ref: String, _ on: [String], _ day: String = "0d",
    why: String = "Acme decision"
  ) throws {
    var input = TaskBlock(why: why)
    input.on = on
    input.followUp = day
    _ = try service.block(ref, input)
  }

  static func items(_ service: TaskService, all: Bool = true) throws -> [[String: Any]] {
    let data = try JSONEncoder().encode(service.inbox(for: "human:acme", all: all))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(object["items"] as? [[String: Any]])
  }

  static func refs(_ item: [String: Any]) -> [String] {
    (item["tasks"] as? [[String: Any]] ?? []).compactMap { $0["ref"] as? String }
  }

  @Test func readinessDroppedPrecedenceAndPerTaskDueFallback() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try TaskServiceTests.environment(home, actor: .human(name: "acme"), clock: clock)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      for _ in 0..<8 { _ = try await Self.add(service, home) }
      try Self.block(service, "AC-2", ["AC-1"], "7d")
      try Self.block(service, "AC-3", ["AC-4", "ext:acme"], "0d")
      try Self.block(service, "AC-5", [], "0d")
      try Self.block(service, "AC-6", ["AC-7"], "0d")
      try Self.block(service, "AC-8", ["ext:future"], "1d")
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET status='done' WHERE seq=1")
        try $0.database.execute(sql: "UPDATE task SET status='dropped' WHERE seq=4")
      }
      let before = try CommentLifecycleTests.snapshot(env)
      let items = try Self.items(service)
      #expect(items.compactMap { $0["kind"] as? String } == ["ready", "replan", "due", "due"])
      #expect(items.map(Self.refs) == [["AC-2"], ["AC-3"], ["AC-5"], ["AC-6"]])
      #expect(items.first?["next"] as? [String] == [
        "silta --ws 'acme' task unblock 'AC-2'", "silta --ws 'acme' task show 'AC-2'",
      ])
      for item in items.dropFirst() {
        #expect((item["next"] as? [String])?.first == "silta --ws 'acme' task ls --status todo")
        #expect(!(item["next"] as? [String] ?? []).contains { $0.contains("unblock") })
      }
      #expect(try CommentLifecycleTests.snapshot(env) == before)
      let agent = TaskService(environment: try TaskServiceTests.environment(home, clock: clock))
      #expect(try agent.inbox().items.isEmpty)
      _ = try service.unblock(["AC-2"])
      #expect(try Self.items(service).map(Self.refs) == [["AC-3"], ["AC-5"], ["AC-6"]])
    }
  }

  @Test func groupingUsesLatestAskEarliestDayAndStableTargetTie() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try TaskServiceTests.environment(home, actor: .human(name: "acme"), clock: clock)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      for _ in 0..<4 { _ = try await Self.add(service, home) }
      try Self.block(service, "AC-1", ["ext:zulu", "ext:alpha"], why: "First ask")
      try Self.block(service, "AC-2", ["ext:alpha", "url:https://example.com/acme"], "1d")
      try Self.block(service, "AC-3", ["ext:alpha"], "1d")
      try Self.block(service, "AC-4", ["ext:alpha"], "3d")
      clock.advance(milliseconds: 86_400_000)
      try Self.block(service, "AC-2", [], why: "Latest ask")
      let items = try Self.items(service)
      #expect(items.compactMap { $0["target"] as? String } == [
        "ext:alpha", "ext:zulu", "url:https://example.com/acme",
      ])
      #expect(items.map(Self.refs) == [["AC-1", "AC-2", "AC-3"], ["AC-1"], ["AC-2"]])
      #expect(items.compactMap { $0["follow_up_at"] as? String } == [
        "2023-11-14", "2023-11-14", "2023-11-15",
      ])
      let tasks = try #require(items.first?["tasks"] as? [[String: Any]])
      #expect(tasks.compactMap { $0["why"] as? String } == ["First ask", "Latest ask", "Acme decision"])
      let before = try CommentLifecycleTests.snapshot(env)
      #expect(try Self.items(service).map(Self.refs) == items.map(Self.refs))
      #expect(try CommentLifecycleTests.snapshot(env) == before)
    }
  }

  @Test func rawURLIdentitiesStaySeparateWhenDisplaysRedactAlike() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home, actor: .human(name: "acme"))
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      _ = try await Self.add(service, home)
      let urls = ["a", "b"].map { "url:https://example.com/?token=ghp_" + String(repeating: $0, count: 36) }
      try Self.block(service, "AC-1", ["url:https://example.com/safe"])
      try env.db.write { tx in
        try tx.database.execute(sql: "UPDATE link SET to_ext=?", arguments: [String(urls[0].dropFirst(4))])
        try tx.database.execute(sql: """
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_ext,created_by,created_at)
          SELECT 'other-url',workspace_id,from_kind,from_id,rel,to_kind,?,created_by,created_at FROM link
          """, arguments: [String(urls[1].dropFirst(4))])
      }
      let items = try Self.items(service)
      #expect(items.count == 2 && items.map(Self.refs) == [["AC-1"], ["AC-1"]])
      #expect(items.compactMap { $0["target"] as? String } == urls.map(SecretGuard.redacted))
      let encoded = try JSONEncoder().encode(service.inbox(for: "human:acme"))
      let text = String(decoding: encoded, as: UTF8.self)
      #expect(!text.contains("ghp_") && text.contains("[REDACTED:github_pat]"))
    }
  }

  @Test func proposalsUseExactFourteenDayBoundaryAndNewestIDTies() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try TaskServiceTests.environment(home, clock: clock)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      for _ in 0..<4 { _ = try await Self.add(service, home) }
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET archive_override='archived' WHERE seq=1")
      }
      clock.advance(milliseconds: 14 * 86_400_000 - 1)
      #expect(try Self.items(service, all: false).map(Self.refs) == [["AC-4"], ["AC-3"], ["AC-2"], ["AC-1"]])
      let before = try CommentLifecycleTests.snapshot(env)
      clock.advance(milliseconds: 1)
      #expect(try Self.items(service, all: false).isEmpty)
      #expect(try Self.items(service).count == 4)
      clock.advance(milliseconds: 1)
      #expect(try Self.items(service, all: false).isEmpty)
      #expect(try CommentLifecycleTests.snapshot(env) == before)
    }
  }

  @Test func fixedGlobalOrderCapAfterGroupingAndVisibility() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home, actor: .human(name: "acme"))
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      for _ in 0..<17 { _ = try await Self.add(service, home) }
      try Self.block(service, "AC-2", ["AC-1"], "7d")
      for seq in 3...15 { try Self.block(service, "AC-\(seq)", ["ext:acme"]) }
      _ = try service.comment("AC-16", CommentDraft(body: "Ask", kind: "question"))
      var answer = CommentDraft(body: "Confirmed", kind: "answer")
      answer.replyTo = "AC-16/1"
      let agent = TaskService(environment: try TaskServiceTests.environment(home))
      _ = try agent.comment("AC-16", answer)
      for _ in 0..<10 { _ = try await Self.add(agent, home) }
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET status='done' WHERE seq=1")
        try $0.database.execute(sql: "UPDATE task SET external_ref='ado:42' WHERE seq=17")
      }
      let all = try Self.items(service)
      #expect(all.compactMap { $0["kind"] as? String } == ["ready", "due", "answer"]
        + Array(repeating: "proposal", count: 10) + ["promoted"])
      try #require(all.count == 14)
      #expect(Self.refs(all[1]).count == 13)
      let limited = try service.inbox()
      #expect(limited.items.count == 12 && limited.remaining == 2)
      #expect(limited.more == "silta --ws 'acme' inbox --for 'human:acme' --all")
      #expect(all.last?["next"] as? [String] == ["silta --ws 'acme' task show 'AC-17'"])
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET archive_override='archived' WHERE seq=17")
        try $0.database.execute(sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','OT')")
      }
      #expect(try Self.items(service).last?["kind"] as? String == "proposal")
      #expect(try TaskService(environment: env, workspace: "other").inbox(all: true).items.isEmpty)
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET archive_override=NULL,status='dropped' WHERE seq=17")
      }
      #expect(try Self.items(service).last?["kind"] as? String == "proposal")
    }
  }
}
