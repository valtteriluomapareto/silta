import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct CommentQuestionTests {
  static func post(
    _ service: TaskService, kind: String = "comment", reply: String? = nil,
    body: String = "Acme", to: [String] = [], source: String? = nil
  ) throws -> CommentDetails {
    var draft = CommentDraft(body: body, kind: kind)
    draft.replyTo = reply
    draft.recipients = to
    draft.source = source
    return try service.comment("AC-1", draft).comment
  }

  @Test func recipientsCitationsAndExplanationMentions() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home)
      let service = TaskService(environment: env)
      let question = try Self.post(service, kind: "question")
      #expect(question.mentions == ["human:unknown"] && !question.accepted)
      let posted = try Self.post(
        service,
        body:
          #"**@human:acme**, `@agent:codex:other`. @human:acme: @me! "#
          + #"mail@acme.test @meeting "@human:acme""#,
        to: ["me", "human:acme"], source: "note:notes/acme.md")
      #expect(posted.mentions == ["human:acme", "human:unknown"])
      #expect(posted.source == "note:notes/acme.md")
      let links = try env.db.read {
        try Row.fetchAll($0, sql: "SELECT * FROM link WHERE from_kind='comment'")
      }
      #expect(links.count == 1 && links.first?["rel"] as String? == "cites")
      #expect(links.first?["to_ext"] as String? == "notes/acme.md")
      _ = try service.updateComments(["AC-1/1"], action: .resolve, explanation: "Ask @me")
      #expect(
        try service.show("AC-1", timeline: true).comments?.last?.mentions == ["human:unknown"])
      let stable = try CommentLifecycleTests.snapshot(env)
      for recipient in [
        "ext:acme", "agent:codex", "agent:Codex:s", "human:a/b",
        "human:" + String(repeating: "a", count: 65),
      ] {
        #expect(throws: CommentError.self) { _ = try Self.post(service, to: [recipient]) }
      }
      for source in [
        "note:", "url:https://acme.test", "note:  ", "note:a\nb", "note:Pwd=acme-value",
      ] {
        #expect(throws: CommentError.self) { _ = try Self.post(service, source: source) }
      }
      for kind in ["question", "comment"] {
        for body in [
          "@me-other", "@me:other", "@human:a/b", "@agent:Codex:s",
          "@human:" + String(repeating: "a", count: 65),
        ] {
          #expect(throws: CommentError.self) { _ = try Self.post(service, kind: kind, body: body) }
        }
      }
      #expect(try CommentLifecycleTests.snapshot(env) == stable)
    }
  }

  @Test func repliesNormalizeAndRejectEveryUnavailableTarget() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home)
      let service = TaskService(environment: env)
      _ = try Self.post(service, kind: "question")
      _ = try Self.post(service, kind: "answer", reply: "AC-1/1")
      #expect(try Self.post(service, kind: "decision", reply: "task:AC-1/2").replyTo == "AC-1/1")
      _ = try Self.post(service)
      for (kind, ref) in [
        ("answer", nil), ("answer", "AC-1/4"), ("question", "AC-1/1"), ("handoff", "AC-1/1"),
        ("comment", "AC-1/99"), ("comment", "AC-1/01"),
      ] {
        #expect(throws: CommentError.self) { _ = try Self.post(service, kind: kind, reply: ref) }
      }
      var task = TaskDraft(title: "Other")
      task.start = true
      _ = try await service.add(task, directory: home)
      _ = try service.comment("AC-2", CommentDraft(body: "Other"))
      #expect(throws: CommentError.self) { _ = try Self.post(service, reply: "AC-2/1") }
      _ = try service.updateComments(["AC-1/2"], action: .delete)
      #expect(throws: CommentError.self) { _ = try Self.post(service, reply: "AC-1/2") }
      _ = try service.updateComments(["AC-1/1"], action: .resolve)
      #expect(throws: CommentError.self) {
        _ = try Self.post(service, kind: "answer", reply: "AC-1/1")
      }
      _ = try service.updateComments(["AC-1/1"], action: .reopen)
      _ = try service.updateComments(["AC-1/1"], action: .delete)
      #expect(throws: CommentError.self) { _ = try Self.post(service, reply: "AC-1/3") }
    }
  }

  @Test(arguments: ["codex", "claude", "human"])
  func acceptanceRequiresWholeAskerAndPreservesForeignClaim(tool: String) async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock)
      let holder = TaskService(environment: env)
      let askerActor: ActorID =
        tool == "human" ? .human(name: "acme") : .agent(tool: tool, session: "asker")
      let asker = TaskService(
        environment: try TaskServiceTests.environment(home, actor: askerActor, clock: clock))
      _ = try Self.post(asker, kind: "question")
      _ = try Self.post(holder, kind: "answer", reply: "AC-1/1")
      let outsider = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: tool == "human" ? "codex" : tool, session: "outsider"),
          clock: clock))
      let before = try holder.show("AC-1"), stable = try CommentLifecycleTests.snapshot(env)
      #expect(throws: CommentError.self) { _ = try outsider.acceptComment("AC-1/2") }
      #expect(try CommentLifecycleTests.snapshot(env) == stable)
      clock.advance(milliseconds: 1000)
      let result = try asker.acceptComment("task:AC-1/2")
      #expect(result.refs == ["AC-1/2"] && result.action == "accepted")
      let after = try holder.show("AC-1", timeline: true)
      #expect(after.claimedAt == before.claimedAt && after.updatedAt == before.updatedAt)
      #expect(after.comments?.first?.resolvedAt == TaskService.timestamp(clock.now()))
      #expect(after.comments?.first?.resolvedBy == askerActor.description)
      #expect(after.comments?.last?.accepted == true)
      #expect(
        after.timeline?.last?.body == "accepted AC-1/2"
          && after.timeline?.last?.actor == askerActor.description)
      let accepted = try CommentLifecycleTests.snapshot(env)
      clock.advance(milliseconds: 1000)
      #expect(try asker.acceptComment("AC-1/2").unchanged == ["AC-1/2"])
      #expect(try CommentLifecycleTests.snapshot(env) == accepted)
      #expect(throws: CommentError.self) { _ = try outsider.acceptComment("AC-1/2") }
      _ = try holder.updateComments(["AC-1/2"], action: .delete)
      let deleted = try #require(holder.show("AC-1", timeline: true).timeline)
      #expect(deleted.last?.body == "deleted AC-1/2")
      #expect(
        deleted.contains { $0.body == "accepted AC-1/2" && $0.actor == askerActor.description })
      #expect(throws: CommentError.self) { _ = try asker.acceptComment("AC-1/2") }
      _ = try holder.updateComments(["AC-1/1"], action: .reopen)
      let reopened = try #require(holder.show("AC-1").comments)
      #expect(reopened.allSatisfy { !$0.accepted && $0.resolvedAt == nil && $0.resolvedBy == nil })
      #expect(
        try holder.show("AC-1", timeline: true).timeline?.contains { $0.body == "accepted AC-1/2" }
          == true)
    }
  }

  @Test func acceptanceStateMatrixAndLateFailuresAreAtomic() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home), service = TaskService(environment: env)
      _ = try Self.post(service, kind: "question")
      for _ in 0..<2 { _ = try Self.post(service, kind: "answer", reply: "AC-1/1") }
      #expect(throws: CommentError.self) { _ = try service.acceptComment("AC-1/1") }
      _ = try service.updateComments(["AC-1/1"], action: .resolve)
      #expect(throws: CommentError.self) { _ = try service.acceptComment("AC-1/2") }
      _ = try service.updateComments(["AC-1/1"], action: .reopen)
      try env.db.write {
        try $0.database.execute(
          sql: """
            CREATE TRIGGER fail_accept BEFORE INSERT ON task_event
            WHEN NEW.kind='discussion' BEGIN SELECT RAISE(ABORT,'Acme failure'); END
            """)
      }
      let stable = try CommentLifecycleTests.snapshot(env)
      #expect(throws: StorageError.self) { _ = try service.acceptComment("AC-1/2") }
      #expect(try CommentLifecycleTests.snapshot(env) == stable)
      try env.db.write { try $0.database.execute(sql: "DROP TRIGGER fail_accept") }
      _ = try service.acceptComment("AC-1/2")
      #expect(throws: CommentError.self) { _ = try service.acceptComment("AC-1/3") }
      _ = try service.updateComments(["AC-1/1"], action: .reopen)
      _ = try service.acceptComment("AC-1/3")
      _ = try service.updateComments(["AC-1/1"], action: .delete)
      #expect(throws: CommentError.self) { _ = try service.acceptComment("AC-1/3") }
      try env.db.write {
        try $0.database.execute(
          sql: """
            CREATE TRIGGER fail_citation BEFORE INSERT ON change_log
            WHEN NEW.kind='link' BEGIN SELECT RAISE(ABORT,'Acme late citation'); END
            """)
      }
      let before = try CommentLifecycleTests.snapshot(env)
      #expect(throws: StorageError.self) {
        _ = try Self.post(service, source: "note:notes/acme.md")
      }
      #expect(try CommentLifecycleTests.snapshot(env) == before)
    }
  }
}

extension CommentQuestionTests {
  @Test(arguments: ["promoted", "done", "dropped"])
  func producerAndAcceptRespectTaskState(state: String) async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home), service = TaskService(environment: env)
      _ = try Self.post(service, kind: "question")
      _ = try Self.post(service, kind: "answer", reply: "AC-1/1")
      try env.db.write {
        try $0.database.execute(
          sql: "UPDATE task SET status=?,external_ref=?",
          arguments: [state == "promoted" ? "doing" : state, state == "promoted" ? "ado:42" : nil])
      }
      let stable = try CommentLifecycleTests.snapshot(env)
      if state == "promoted" {
        #expect(throws: TaskError.self) { _ = try Self.post(service, reply: "AC-1/1") }
        #expect(throws: TaskError.self) { _ = try service.acceptComment("AC-1/2") }
        #expect(try CommentLifecycleTests.snapshot(env) == stable)
      } else {
        #expect(try Self.post(service, reply: "AC-1/1").replyTo == "AC-1/1")
        _ = try service.acceptComment("AC-1/2")
        #expect(try service.show("AC-1").status == state)
      }
    }
  }

  @Test(arguments: ["acme", "bad/user", ""])
  func capturedHumanIsIndependentOfCaller(user: String) async throws {
    try await withScratchDirectory { home in
      let env = try await SiltaEnvironment.system(environment: [
        "SILTA_HOME": home.path, "USER": user, "SILTA_ACTOR": "agent:codex:other",
      ])
      #expect(env.actor == .agent(tool: "codex", session: "other"))
      #expect(env.human == .human(name: user == "acme" ? "acme" : "unknown"))
      #expect(ActorID.parse("agent:Codex:other") == nil && ActorID.parse("agent:codex") == nil)
      #expect(ActorID.parse("human:acme") == .human(name: "acme"))
    }
  }

  @Test func secretsConsentAndSuppliedMetadataAuditRemainAtomic() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home), service = TaskService(environment: env)
      _ = try Self.post(service, kind: "question")
      var draft = CommentDraft(body: "Pwd=" + "acme-value", kind: "answer")
      draft.replyTo = "AC-1/1"
      draft.recipients = ["me"]
      draft.source = "note:notes/acme.md"
      let redacted = try service.comment("AC-1", draft)
      #expect(
        !redacted.comment.body.contains("acme-value") && redacted.warnings == [SecretGuard.warning])
      draft.allowSecret = true
      let stable = try CommentLifecycleTests.snapshot(env)
      #expect(throws: ActorError.self) { _ = try service.comment("AC-1", draft) }
      #expect(try CommentLifecycleTests.snapshot(env) == stable)
      let approved = TaskService(
        environment: env, workspace: "acme", approved: "Keep Acme content", bodyFlag: "-F <file>")
      #expect(try approved.comment("AC-1", draft).approvalUsed)
      let audit = try env.db.read { try String.fetchOne($0, sql: "SELECT command FROM approval") }
      #expect(
        audit
          == "silta --ws 'acme' comment 'AC-1' --kind 'answer' --reply-to 'AC-1/1'"
          + " --to 'me' --from 'note:notes/acme.md' -F <file> --allow-secret -> AC-1/3"
      )
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
      #expect(audit?.contains("acme-value") == false)
      var explicit = CommentDraft(body: "Acme", kind: "comment")
      explicit.allowSecret = true
      _ = try approved.comment("AC-1", explicit)
      let last = try env.db.read {
        try String.fetchOne($0, sql: "SELECT command FROM approval ORDER BY rowid DESC LIMIT 1")
      }
      #expect(
        last
          == "silta --ws 'acme' comment 'AC-1' --kind 'comment' -F <file> --allow-secret -> AC-1/4")
    }
  }
}

extension CommentQuestionTests {
  @Test func explicitQuestionRecipientsSuppressDefaultAndWorkspaceRepliesRefuse() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home), service = TaskService(environment: env)
      #expect(
        try Self.post(service, kind: "question", body: "Ask @agent:codex:other").mentions == [
          "agent:codex:other"
        ])
      #expect(
        try Self.post(service, kind: "question", to: ["human:acme"]).mentions == ["human:acme"])
      try env.db.write {
        try $0.database.execute(
          sql:
            "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','OT')")
      }
      let other = TaskService(environment: env, workspace: "other")
      var task = TaskDraft(title: "Other")
      task.start = true
      _ = try await other.add(task, directory: home)
      _ = try other.comment("OT-1", CommentDraft(body: "Other", kind: "question"))
      let stable = try CommentLifecycleTests.snapshot(env)
      #expect(throws: TaskError.self) { _ = try Self.post(service, reply: "OT-1/1") }
      #expect(throws: TaskError.self) { _ = try service.acceptComment("OT-1/1") }
      #expect(try CommentLifecycleTests.snapshot(env) == stable)
    }
  }
}
