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

  static func block(
    _ service: TaskService, _ ref: String, _ on: [String], _ day: String = "0d",
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

  @Test(arguments: ["0d", "7d"])
  func readinessDroppedPrecedenceAndPerTaskDueFallback(followUp: String) async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try TaskServiceTests.environment(home, actor: .human(name: "acme"), clock: clock)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      for _ in 0..<8 { _ = try await Self.add(service, home) }
      try Self.block(service, "AC-2", ["AC-1"], "7d")
      try Self.block(service, "AC-3", ["AC-4", "ext:acme"], followUp)
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
      #expect(
        items.first?["next"] as? [String] == [
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
      #expect(
        items.compactMap { $0["target"] as? String } == [
          "ext:alpha", "ext:zulu", "url:https://example.com/acme",
        ])
      #expect(items.map(Self.refs) == [["AC-1", "AC-2", "AC-3"], ["AC-1"], ["AC-2"]])
      #expect(
        items.compactMap { $0["follow_up_at"] as? String } == [
          "2023-11-14", "2023-11-14", "2023-11-15",
        ])
      #expect(
        items.first?["next"] as? [String] == [
          "silta --ws 'acme' task ls --status todo",
          "silta --ws 'acme' task show 'AC-1'", "silta --ws 'acme' task show 'AC-2'",
          "silta --ws 'acme' task show 'AC-3'",
        ])
      let tasks = try #require(items.first?["tasks"] as? [[String: Any]])
      #expect(
        tasks.compactMap { $0["why"] as? String } == ["First ask", "Latest ask", "Acme decision"])
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
      let urls = ["a", "b"].map {
        "url:https://example.com/?token=ghp_" + String(repeating: $0, count: 36)
      }
      try Self.block(service, "AC-1", ["url:https://example.com/safe"])
      try env.db.write { tx in
        try tx.database.execute(
          sql: "UPDATE link SET to_ext=?", arguments: [String(urls[0].dropFirst(4))])
        try tx.database.execute(
          sql: """
            INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_ext,
              created_by,created_at)
            SELECT 'other-url',workspace_id,from_kind,from_id,rel,to_kind,?,created_by,created_at
            FROM link
            """, arguments: [String(urls[1].dropFirst(4))])
      }
      let items = try Self.items(service)
      #expect(items.count == 2 && items.map(Self.refs) == [["AC-1"], ["AC-1"]])
      #expect(items.compactMap { $0["target"] as? String } == urls.map(SecretGuard.redacted))
      let encoded = try JSONEncoder().encode(service.inbox(for: "human:acme"))
      let text = try #require(String(bytes: encoded, encoding: .utf8))
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
      #expect(
        try Self.items(service, all: false).map(Self.refs) == [
          ["AC-4"], ["AC-3"], ["AC-2"], ["AC-1"],
        ])
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
      var question = CommentDraft(body: "Another choice", kind: "question")
      question.recipients = ["human:acme"]
      _ = try agent.comment("AC-16", question)
      for _ in 0..<10 { _ = try await Self.add(agent, home) }
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET status='done' WHERE seq=1")
        try $0.database.execute(sql: "UPDATE task SET external_ref='ado:42' WHERE seq=17")
      }
      let all = try Self.items(service)
      #expect(
        all.compactMap { $0["kind"] as? String } == ["ready", "due", "question", "answer"]
          + Array(repeating: "proposal", count: 10) + ["promoted"])
      try #require(all.count == 15)
      #expect(Self.refs(all[1]).count == 13)
      let limited = try service.inbox()
      #expect(limited.items.count == 12 && limited.remaining == 3)
      #expect(limited.more == "silta --ws 'acme' inbox --for 'human:acme' --all")
      #expect(all.last?["next"] as? [String] == ["silta --ws 'acme' task show 'AC-17'"])
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET archive_override='archived' WHERE seq=17")
        try $0.database.execute(
          sql:
            "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','OT')")
      }
      #expect(try Self.items(service).last?["kind"] as? String == "proposal")
      #expect(try TaskService(environment: env, workspace: "other").inbox(all: true).items.isEmpty)
      try env.db.write {
        try $0.database.execute(
          sql: "UPDATE task SET archive_override=NULL,status='dropped' WHERE seq=17")
      }
      #expect(try Self.items(service).last?["kind"] as? String == "proposal")
    }
  }
  @Test func dueUsesExactUTCDayAndPromotedDoneBlockerStaysUnmet() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try TaskServiceTests.environment(home, actor: .human(name: "acme"), clock: clock)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      for _ in 0..<3 { _ = try await Self.add(service, home) }
      try Self.block(service, "AC-2", ["AC-1"], "1d")
      try Self.block(service, "AC-3", ["ext:acme"], "1d")
      try env.db.write {
        try $0.database.execute(
          sql: "UPDATE task SET status='done',external_ref='ado:42' WHERE seq=1")
        try $0.database.execute(sql: "UPDATE task SET archive_override='archived' WHERE seq=2")
      }
      clock.advance(milliseconds: 6_399_999)
      #expect(try Self.items(service).isEmpty)
      clock.advance(milliseconds: 1)
      let due = try Self.items(service)
      #expect(due.map(Self.refs) == [["AC-2"], ["AC-3"]])
      #expect(due.compactMap { $0["kind"] as? String } == ["due", "due"])
      #expect((due.first?["next"] as? [String])?.first == "silta --ws 'acme' task ls --status todo")
    }
  }

}

extension InboxGroupTests {
  @Test func proposalTimePrecedesIDAndMixedBlockersRemainUnmet() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home, actor: .human(name: "acme"))
      try TaskServiceTests.setup(env)
      let human = TaskService(environment: env)
      for _ in 0..<4 { _ = try await Self.add(human, home) }
      try Self.block(human, "AC-3", ["AC-1", "AC-2"])
      try Self.block(human, "AC-4", ["AC-1", "ext:acme"])
      let agent = TaskService(environment: try TaskServiceTests.environment(home))
      for _ in 0..<4 { _ = try await Self.add(agent, home) }
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET status='done' WHERE seq=1")
        try $0.database.execute(
          sql: "UPDATE task SET created_at='2023-11-13T00:00:00.000Z' WHERE seq=8")
        try $0.database.execute(
          sql: "UPDATE task SET created_at='2023-11-14T22:13:20.001Z' WHERE seq=5")
      }
      for _ in 0..<2 { _ = try await Self.add(human, home) }
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET external_ref='ado:42' WHERE seq IN (9,10)")
      }
      let items = try Self.items(human)
      #expect(
        items.compactMap { $0["kind"] as? String } == [
          "due", "due", "proposal", "proposal", "proposal", "proposal", "promoted", "promoted",
        ])
      #expect(
        items.map(Self.refs) == [
          ["AC-3"], ["AC-4"], ["AC-5"], ["AC-7"], ["AC-6"], ["AC-8"], ["AC-9"], ["AC-10"],
        ])
      try #require(items.count == 8)
      #expect(
        items[2]["next"] as? [String] == [
          "silta --ws 'acme' task triage --accept 'AC-5'",
          "silta --ws 'acme' task triage --drop 'AC-5'",
          "silta --ws 'acme' task show 'AC-5'",
        ])
    }
  }

}
