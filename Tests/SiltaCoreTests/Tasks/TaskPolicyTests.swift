import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskPolicyTests {
  @Test func workspaceSequencesFiltersAndRefsStayIsolated() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      try env.db.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix)
            VALUES('other','other','Acme Other','OT')
            """)
      }
      var draft = TaskDraft(title: "Scoped")
      draft.start = true
      draft.source = "note:notes/acme.md"
      draft.topics = ["release", "release"]
      let acme = TaskService(environment: env)
      _ = try await acme.add(draft, directory: home)
      _ = try acme.submit("AC-1")
      var child = TaskDraft(title: "Child under review")
      child.parent = "AC-1"
      #expect(try await acme.add(child, directory: home).status == "todo")
      let other = TaskService(environment: env, workspace: "other")
      #expect(
        try await other.add(TaskDraft(title: "Other workspace"), directory: home).ref == "OT-1")
      #expect(try acme.list().map(\.ref) == ["AC-1", "AC-2"])
      #expect(throws: TaskError.self) { _ = try acme.show("OT-1") }
      let task = try acme.show("AC-1")
      #expect(
        task.links == [
          TaskLink(rel: "about", target: "topic:release"),
          TaskLink(rel: "source", target: "note:notes/acme.md"),
        ])
      var filter = TaskFilter()
      filter.topic = "release"
      #expect(try acme.list(filter).map(\.ref) == ["AC-1"])
      filter.status = "todo"
      #expect(try acme.list(filter).isEmpty)
      filter.status = "typo"
      #expect(throws: TaskError.self) { _ = try acme.list(filter) }
    }
  }

  @Test func humanApprovalAndAnyLatestVerdictAreEnforced() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      var draft = TaskDraft(title: "Review")
      draft.start = true
      _ = try await service.add(draft, directory: home)
      try env.db.write {
        try $0.database.execute(sql: "UPDATE workspace SET settings='{\"review_gate\":\"human\"}'")
      }
      try Self.verdict("approve", actor: TaskServiceTests.agent, in: env.db)
      await #expect(throws: TaskError.gate("AC-1")) {
        _ = try await service.close("AC-1", result: "Done.", directory: home)
      }
      try Self.verdict("approve", actor: TaskServiceTests.human(), in: env.db)
      _ = try await service.close("AC-1", result: "Approved.", directory: home)
      _ = try await service.add(draft, directory: home)
      try env.db.write {
        try $0.database.execute(sql: "UPDATE workspace SET settings='{\"review_gate\":\"any\"}'")
      }
      try Self.verdict("changes", actor: TaskServiceTests.agent, task: 2, in: env.db)
      #expect(
        try await service.close("AC-2", result: "Done with warning.", directory: home).result
          .warnings.map(
            \.code) == ["review_changes"])
    }
  }

  private static func verdict(
    _ verdict: String, actor: ActorID, task: Int64 = 1, in store: DatabaseStore
  ) throws {
    try store.write { tx in
      let sequence = try tx.nextSequence(scope: "test-comment:\(task)")
      try tx.database.execute(
        sql: """
          INSERT INTO comment(uid,task_id,seq,kind,verdict,body_md,actor,created_at)
          VALUES(?,?,?,'review',?,'Review',?,'2023-11-14T22:13:20.000Z')
          """,
        arguments: ["review-\(task)-\(sequence)", task, sequence, verdict, actor.description])
    }
  }
}

extension TaskPolicyTests {
  @Test func invalidInputsAndOtherProposalsNeverWrite() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      await #expect(throws: TaskError.self) {
        _ = try await service.add(TaskDraft(title: " \n"), directory: home)
      }
      var draft = TaskDraft(title: "Source")
      draft.source = "url:https://acme.example"
      await #expect(throws: TaskError.self) { _ = try await service.add(draft, directory: home) }
      draft.source = "note:"
      await #expect(throws: TaskError.self) { _ = try await service.add(draft, directory: home) }
      _ = try await service.add(TaskDraft(title: "Proposal"), directory: home)
      let rival = TaskService(
        environment: try TaskServiceTests.environment(
          home,
          actor: .agent(tool: "codex", session: "other")))
      await #expect(throws: TaskError.proposal("AC-1")) {
        _ = try await rival.close(
          "AC-1", result: "Should not close.", dropped: true, directory: home)
      }
      var filter = TaskFilter()
      filter.proposed = true
      #expect(try rival.list(filter).count == 1)
      filter.mine = true
      #expect(try rival.list(filter).isEmpty)
      #expect(try service.show("AC-1").status == "proposed")
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task_event") } == 1)
      #expect(
        try env.db.read {
          try Int.fetchOne($0, sql: "SELECT count(*) FROM change_log WHERE kind='task'")
        } == 1)
    }
  }

  @Test func malformedClaimHeartbeatFailsClosed() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      var draft = TaskDraft(title: "Claim")
      draft.start = true
      _ = try await TaskService(environment: env).add(draft, directory: home)
      let rival = TaskService(
        environment: try TaskServiceTests.environment(
          home,
          actor: .agent(tool: "codex", session: "other")))
      for timestamp in [nil, "malformed"] as [String?] {
        try env.db.write {
          try $0.database.execute(sql: "UPDATE task SET claimed_at=?", arguments: [timestamp])
        }
        await #expect(throws: StorageError.unavailable) {
          _ = try await rival.start("AC-1", directory: home)
        }
      }
    }
  }
}

extension TaskPolicyTests {
  @Test func exclusiveCommitOptionsAndSubmitSourceStatusAreChecked() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      _ = try await service.add(TaskDraft(title: "Proposal"), directory: home)
      #expect(throws: TaskError.transition("AC-1", status: "proposed")) {
        _ = try service.submit("AC-1")
      }
      var draft = TaskDraft(title: "Requested")
      draft.start = true
      _ = try await service.add(draft, directory: home)
      var commit = TaskCommit()
      commit.sha = "HEAD"
      commit.noSHA = true
      await #expect(throws: TaskError.invalid("--sha and --no-sha cannot be combined.")) {
        _ = try await service.close("AC-2", result: "Done.", commit: commit, directory: home)
      }
      commit.noSHA = false
      await #expect(throws: TaskError.invalid("--sha requires an app task completed with done.")) {
        _ = try await service.close("AC-2", result: "Done.", commit: commit, directory: home)
      }
      draft.allowSecret = true
      await #expect(throws: ActorError.self) { _ = try await service.add(draft, directory: home) }
      #expect(throws: TaskError.notFound) { _ = try service.show("AC-99") }
    }
  }
}
