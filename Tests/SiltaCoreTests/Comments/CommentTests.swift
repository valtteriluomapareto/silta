import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CommentTests {
  static func snapshot(_ env: SiltaEnvironment) throws -> [Int] {
    try ProposalPolicyTests.snapshot(env)
      + env.db.read { db in
        [try #require(try Int.fetchOne(db, sql: "SELECT count(*) FROM comment"))]
      }
  }

  static func setup(_ home: URL, clock: FakeClock = FakeClock(now: TaskServiceTests.now))
    async throws -> SiltaEnvironment
  {
    let env = try TaskServiceTests.environment(home, clock: clock)
    try TaskServiceTests.setup(env)
    var task = TaskDraft(title: "Acme")
    task.start = true
    _ = try await TaskService(environment: env).add(task, directory: home)
    return env
  }

  @Test func discussionAndHandoffRespectTheClaimHolder() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await Self.setup(home, clock: clock)
      let owner = TaskService(environment: env)
      let before = try owner.show("AC-1")
      let foreign = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: "claude", session: "reviewer"), clock: clock))
      clock.advance(milliseconds: 1000)
      _ = try foreign.comment("AC-1", CommentDraft(body: "Reviewer finding"))
      #expect(try owner.show("AC-1").claimedAt == before.claimedAt)
      #expect(try owner.show("AC-1").updatedAt == before.updatedAt)
      #expect(throws: CommentError.self) {
        _ = try foreign.comment("AC-1", CommentDraft(body: "Stopped", kind: "handoff"))
      }
      _ = try owner.comment("task:AC-1", CommentDraft(body: "Finding addressed"))
      #expect(try owner.show("AC-1").claimedAt == TaskService.timestamp(clock.now()))
      let handoff = try owner.comment(
        "AC-1", CommentDraft(body: "Continue tests.", kind: "handoff"))
      let shown = try owner.show("AC-1")
      #expect(shown.status == "doing" && shown.claimedBy == nil && shown.claimedAt == nil)
      #expect(shown.comments?.map(\.ref) == [handoff.comment.ref, "AC-1/1", "AC-1/2"])
      #expect(try await foreign.start("AC-1", directory: home).result.status == "doing")
      #expect(try foreign.show("AC-1").comments?.last?.body == "Finding addressed")
    }
  }

  @Test(arguments: ["comment", "decision", "handoff"])
  func unclaimedDiscussionRecordsContext(kind: String) async throws {
    try await withScratchDirectory { home in
      let service = TaskService(environment: try await Self.setup(home))
      _ = try service.submit("AC-1")
      let result = try service.comment("AC-1", CommentDraft(body: "Acme context", kind: kind))
      #expect(result.warnings.contains { $0.code == "handoff_unclaimed" } == (kind == "handoff"))
      #expect(try service.show("AC-1").status == "review")
    }
  }

  @Test(arguments: [8000, 8001])
  func scalarLimitIsNotGraphemeCount(count: Int) async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      let draft = CommentDraft(
        body: String(repeating: "e\u{301}", count: count / 2) + (count % 2 == 1 ? "x" : ""))
      let before = try Self.snapshot(env)
      if count == 8000 {
        #expect(
          try TaskService(environment: env).comment("AC-1", draft).comment.body.unicodeScalars.count
            == 8000)
      } else {
        #expect(throws: CommentError.self) {
          _ = try TaskService(environment: env).comment("AC-1", draft)
        }
        #expect(try Self.snapshot(env) == before)
      }
    }
  }

  @Test func workspaceAndTaskStateBoundariesHold() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      let service = TaskService(environment: env)
      try env.db.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','OT')
            """)
      }
      let other = TaskService(environment: env, workspace: "other")
      var task = TaskDraft(title: "Other")
      task.start = true
      _ = try await other.add(task, directory: home)
      _ = try service.comment("AC-1", CommentDraft(body: "Acme"))
      _ = try other.comment("OT-1", CommentDraft(body: "Other"))
      #expect(try service.show("AC-1").comments?.map(\.body) == ["Acme"])
      #expect(try other.show("OT-1").comments?.map(\.body) == ["Other"])
      #expect(throws: TaskError.self) { _ = try other.comment("AC-1", CommentDraft(body: "Wrong")) }
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET external_ref='ado:42' WHERE id=1")
      }
      #expect(throws: TaskError.self) {
        _ = try service.comment("AC-1", CommentDraft(body: "Readonly"))
      }
      for status in ["done", "dropped"] {
        try env.db.write {
          try $0.database.execute(
            sql: """
              UPDATE task SET external_ref=NULL,status=?,closed_at=?,
              claimed_by=NULL,claimed_at=NULL WHERE id=1
              """, arguments: [status, TaskService.timestamp(env.clock.now())])
        }
        #expect(
          try service.comment("AC-1", CommentDraft(body: "Closed context")).comment.kind
            == "comment")
      }
    }
  }

  @Test func storedDiscussionRemainsReadableAndScoped() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      try env.db.write { tx in
        for (offset, kind) in [
          "review", "future", "comment", "comment", "comment", "handoff", "handoff", "comment",
          "question", "answer",
        ].enumerated() {
          let seq = offset + 1
          try tx.database.execute(
            sql: """
              INSERT INTO comment(id,uid,task_id,seq,kind,body_md,actor,created_at,
                deleted_at,resolved_at,thread_id)
              VALUES(?,?,1,?,?,'Hidden if deleted','agent:codex:acme','t',?,?,?)
              """,
            arguments: [
              seq, "c\(seq)", seq, kind, [4, 8].contains(seq) ? "x" : nil,
              seq == 3 ? "x" : nil, seq == 5 ? 4 : seq == 10 ? 9 : nil,
            ])
        }
      }
      let service = TaskService(environment: env)
      let shown = try #require(service.show("AC-1").comments)
      #expect(
        shown.map(\.ref) == ["AC-1/7", "AC-1/1", "AC-1/2", "AC-1/4", "AC-1/5", "AC-1/9", "AC-1/10"])
      #expect(shown.first { $0.deleted }?.body == "[deleted]")
      #expect(try service.show("AC-1", timeline: true).comments?.count == 10)
      #expect(try service.comment("AC-1", CommentDraft(body: "Next")).comment.ref == "AC-1/11")
    }
  }
}

extension CommentTests {
  @Test func secretsAndLateHandoffFailureNeverPartiallyCommit() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await Self.setup(home, clock: clock)
      let service = TaskService(environment: env)
      let secret = "Pwd=" + "acme-value"
      let masked = try service.comment("AC-1", CommentDraft(body: secret))
      #expect(
        !masked.comment.body.contains("acme-value") && masked.warnings == [SecretGuard.warning])
      var draft = CommentDraft(body: secret)
      draft.allowSecret = true
      let before = try Self.snapshot(env)
      #expect(throws: ActorError.self) { _ = try service.comment("AC-1", draft) }
      #expect(try Self.snapshot(env) == before)
      let approved = TaskService(
        environment: env, approved: "Keep Acme content", bodyFlag: "-m <text>")
      #expect(try approved.comment("AC-1", draft).comment.body == secret)
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
      #expect(
        try env.db.read { try String.fetchOne($0, sql: "SELECT command FROM approval") }?.contains(
          "acme-value") == false)
      try env.db.write {
        try $0.database.execute(
          sql: """
            CREATE TRIGGER fail_comment_change BEFORE INSERT ON change_log WHEN NEW.kind='comment'
            BEGIN SELECT RAISE(ABORT,'Acme failure'); END
            """)
      }
      let stable = try Self.snapshot(env), claim = try service.show("AC-1")
      clock.advance(milliseconds: 1000)
      draft.kind = "handoff"
      #expect(throws: StorageError.self) { _ = try approved.comment("AC-1", draft) }
      #expect(try Self.snapshot(env) == stable)
      let after = try service.show("AC-1")
      #expect(after.claimedBy == claim.claimedBy && after.claimedAt == claim.claimedAt)
      #expect(after.updatedAt == claim.updatedAt && after.status == claim.status)
      for kind in ["question", "answer", "review", "future"] {
        #expect(throws: CommentError.self) {
          _ = try service.comment("AC-1", CommentDraft(body: "Acme", kind: kind))
        }
      }
      #expect(throws: CommentError.self) {
        _ = try service.comment("AC-1", CommentDraft(body: " "))
      }
    }
  }

  @Test func independentConnectionsAllocateMonotonicTaskRefs() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      let service = TaskService(environment: env)
      _ = try service.comment("AC-1", CommentDraft(body: "Retained"))
      try env.db.write { try $0.database.execute(sql: "UPDATE comment SET deleted_at='x'") }
      let refs = try await withThrowingTaskGroup(of: String.self) { group in
        for index in 0..<8 {
          group.addTask {
            let connection = try TaskServiceTests.environment(
              home, actor: .agent(tool: "codex", session: "p\(index)"))
            return try TaskService(environment: connection).comment(
              "AC-1", CommentDraft(body: "Acme \(index)")
            ).comment.ref
          }
        }
        var values: [String] = []
        for try await ref in group { values.append(ref) }
        return values
      }
      #expect(Set(refs) == Set((2...9).map { "AC-1/\($0)" }))
      #expect(try service.show("AC-1", timeline: true).comments?.count == 9)
    }
  }
}
