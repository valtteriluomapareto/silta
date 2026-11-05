import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct CommentLifecycleTests {
  static func snapshot(_ env: SiltaEnvironment) throws -> [String] {
    try env.db.read { db in
      try [
        "task", "comment", "task_event", "change_log", "approval", "link", "meta", "seq_counter",
      ].flatMap { table in
        try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { "\(table): \($0)" }
      }
    }
  }

  @Test func orderedBatchesNormalizeRepliesAndNoopsWriteNothing() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock)
      let service = TaskService(environment: env)
      var task = TaskDraft(title: "Acme second")
      task.start = true
      _ = try await service.add(task, directory: home)
      for ref in ["AC-1", "AC-2"] { _ = try service.comment(ref, CommentDraft(body: "Finding")) }
      let batch = ["AC-2/1", "task:AC-1/1", "AC-2/1"]
      let resolved = try service.updateComments(batch, action: .resolve, explanation: "Fixed")
      #expect(resolved.refs == ["AC-2/1", "AC-1/1"])
      #expect(resolved.created == ["AC-2/2", "AC-1/2"])
      let stable = try Self.snapshot(env)
      clock.advance(milliseconds: 1000)
      _ = try service.updateComments(batch, action: .resolve, explanation: "No duplicate")
      #expect(try Self.snapshot(env) == stable)
      let reopened = try service.updateComments(["AC-1/2", "AC-1/1"], action: .reopen)
      #expect(reopened.refs == ["AC-1/1"] && reopened.created.isEmpty)
      let posts = try #require(service.show("AC-1").comments)
      #expect(posts.map(\.replyTo) == [nil, "AC-1/1"])
      let open = try Self.snapshot(env)
      clock.advance(milliseconds: 1000)
      _ = try service.updateComments(["AC-1/2"], action: .reopen, explanation: "No duplicate")
      #expect(try Self.snapshot(env) == open)
      _ = try service.updateComments(["AC-1/2"], action: .delete)
      let deleted = try Self.snapshot(env)
      clock.advance(milliseconds: 1000)
      _ = try service.updateComments(["AC-1/2"], action: .delete)
      #expect(try Self.snapshot(env) == deleted)
      #expect(try service.show("AC-1").comments?.first?.deleted == false)
    }
  }

  @Test(arguments: ["codex", "claude", "human"])
  func foreignLifecyclePreservesClaimAndDeleteChecksWholeAuthor(tool: String) async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock)
      let owner = TaskService(environment: env)
      _ = try owner.comment("AC-1", CommentDraft(body: "Private finding"))
      let actor: ActorID
      if tool == "human" {
        actor = try TaskServiceTests.human()
      } else {
        actor = .agent(tool: tool, session: "reviewer")
      }
      let foreign = TaskService(
        environment: try TaskServiceTests.environment(home, actor: actor, clock: clock))
      let before = try owner.show("AC-1")
      clock.advance(milliseconds: 1000)
      _ = try foreign.updateComments(["AC-1/1"], action: .resolve, explanation: "Reviewed")
      let after = try owner.show("AC-1")
      #expect(after.claimedBy == before.claimedBy && after.claimedAt == before.claimedAt)
      #expect(after.updatedAt == before.updatedAt)
      for deleted in [false, true] {
        if deleted { _ = try owner.updateComments(["AC-1/1"], action: .delete) }
        let stable = try Self.snapshot(env)
        do {
          _ = try foreign.updateComments(["AC-1/1"], action: .delete)
          Issue.record("Wrong author deleted a comment")
        } catch let error as CommentError { #expect(error.code == .conflict) }
        #expect(try Self.snapshot(env) == stable)
      }
      _ = try foreign.updateComments(["AC-1/2"], action: .reopen)
      let visible = try #require(owner.show("AC-1").comments)
      #expect(visible.map(\.ref) == ["AC-1/1", "AC-1/2"])
      #expect(visible.first?.body == "[deleted]" && visible.last?.body == "Reviewed")
      _ = try foreign.updateComments(["AC-1/1"], action: .resolve)
      #expect(try owner.show("AC-1").comments == nil)
      #expect(try owner.show("AC-1", timeline: true).comments?.first?.body == "[deleted]")
    }
  }

  @Test func malformedOrMissingBatchTargetsWriteNothing() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home)
      let service = TaskService(environment: env)
      _ = try service.comment("AC-1", CommentDraft(body: "Finding"))
      let stable = try Self.snapshot(env)
      for ref in ["AC-1/01", "AC-1/0", "AC-1/999", "OT-1/1", "AC-1/1/2"] {
        do {
          _ = try service.updateComments(["AC-1/1", ref], action: .resolve)
          Issue.record("Invalid comment target accepted")
        } catch let error as any CodedError {
          #expect(error.code == (ref == "AC-1/999" ? .notFound : .invalid))
        }
        #expect(try Self.snapshot(env) == stable)
      }
    }
  }

  @Test func failuresRollbackEveryRootExplanationConsentAndHeartbeat() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock)
      let service = TaskService(
        environment: env, approved: "Keep Acme context", bodyFlag: "-F <file>")
      var task = TaskDraft(title: "Acme second")
      task.start = true
      _ = try await service.add(task, directory: home)
      for ref in ["AC-1", "AC-2"] { _ = try service.comment(ref, CommentDraft(body: "Finding")) }
      let stable = try Self.snapshot(env)
      try env.db.write {
        try $0.database.execute(
          sql: """
            CREATE TRIGGER fail_second BEFORE UPDATE ON comment
            WHEN OLD.task_id=2 AND NEW.resolved_at IS NOT NULL
            BEGIN SELECT RAISE(ABORT,'Acme late failure'); END
            """)
      }
      clock.advance(milliseconds: 1000)
      let secret = "Pwd=" + "acme-value"
      #expect(throws: StorageError.self) {
        _ = try service.updateComments(
          ["AC-1/1", "AC-2/1"], action: .resolve, explanation: secret, allowSecret: true)
      }
      #expect(try Self.snapshot(env) == stable)
      try env.db.write { try $0.database.execute(sql: "DROP TRIGGER fail_second") }
      let result = try service.updateComments(
        ["AC-1/1", "AC-2/1"], action: .resolve, explanation: secret, allowSecret: true)
      #expect(result.approvalUsed)
      let approved = try Self.snapshot(env)
      clock.advance(milliseconds: 1000)
      let noop = try service.updateComments(
        ["AC-1/1", "AC-2/1"], action: .resolve, explanation: secret, allowSecret: true)
      #expect(try !noop.approvalUsed && Self.snapshot(env) == approved)
      #expect(
        try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
      #expect(
        try env.db.read { try String.fetchOne($0, sql: "SELECT command FROM approval") }
          == "silta comment resolve 'AC-1/1' 'AC-2/1' -F <file> --allow-secret -> AC-1/2 AC-2/2")
      _ = try service.updateComments(["AC-1/1"], action: .reopen, explanation: secret)
      let shown = try #require(service.show("AC-1", timeline: true).comments)
      #expect(shown.last?.body.contains("acme-value") == false)
      #expect(try service.show("AC-1", timeline: true).timeline?.last?.body == "AC-1/3")
    }
  }
}

extension CommentLifecycleTests {
  @Test(arguments: ["promoted", "done", "dropped"])
  func lifecycleKeepsTaskStateBoundaries(state: String) async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home)
      let service = TaskService(environment: env)
      _ = try service.comment("AC-1", CommentDraft(body: "Acme finding"))
      try env.db.write {
        try $0.database.execute(
          sql: "UPDATE task SET status=?,external_ref=?",
          arguments: [state == "promoted" ? "doing" : state, state == "promoted" ? "ado:42" : nil])
      }
      let before = try Self.snapshot(env)
      if state == "promoted" {
        for action in [CommentAction.resolve, .reopen, .delete] {
          do {
            _ = try service.updateComments(["AC-1/1"], action: action)
            Issue.record("Promoted discussion changed")
          } catch let error as TaskError { #expect(error.code == .readOnlyPromoted) }
          #expect(try Self.snapshot(env) == before)
        }
      } else {
        _ = try service.updateComments(["AC-1/1"], action: .resolve)
        _ = try service.updateComments(["AC-1/1"], action: .delete)
        #expect(try service.show("AC-1").status == state)
      }
    }
  }
}

extension CommentLifecycleTests {
  @Test(arguments: [0, 8001])
  func invalidExplanationsPreserveTheThread(scalars: Int) async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home)
      let service = TaskService(environment: env)
      _ = try service.comment("AC-1", CommentDraft(body: "Finding"))
      let before = try Self.snapshot(env)
      #expect(throws: CommentError.self) {
        _ = try service.updateComments(
          ["AC-1/1"], action: .resolve, explanation: String(repeating: "x", count: scalars))
      }
      #expect(try Self.snapshot(env) == before)
    }
  }
}

extension CommentLifecycleTests {
  @Test func mixedStateBatchChangesOnlyTheOpenRoot() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock)
      let service = TaskService(
        environment: env, approved: "Keep Acme context", bodyFlag: "-m <text>")
      var task = TaskDraft(title: "Acme second")
      task.start = true
      _ = try await service.add(task, directory: home)
      for ref in ["AC-1", "AC-2"] { _ = try service.comment(ref, CommentDraft(body: "Finding")) }
      _ = try service.updateComments(["AC-1/1"], action: .resolve)
      let before = try service.show("AC-1", timeline: true)
      clock.advance(milliseconds: 1000)
      let result = try service.updateComments(
        ["AC-1/1", "AC-2/1"], action: .resolve, explanation: "Pwd=" + "acme-value",
        allowSecret: true)
      #expect(result.created == ["AC-2/2"] && result.approvalUsed)
      let after = try service.show("AC-1", timeline: true)
      #expect(after.claimedAt == before.claimedAt && after.updatedAt == before.updatedAt)
      #expect(after.comments?.count == 1 && after.timeline?.count == before.timeline?.count)
      #expect(try service.show("AC-2").claimedAt == TaskService.timestamp(clock.now()))
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
    }
  }
}
