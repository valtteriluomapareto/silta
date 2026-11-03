import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskBlockGuardTests {
  @Test func claimsPromotionAndBlockedStartPrecedeGit() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let service = try TaskOrganizationTests.service(home, clock: clock)
      try await TaskBlockTests.add(service, count: 2, directory: home)
      let other = TaskService(
        environment: try TaskServiceTests.environment(
          home,
          actor: .agent(tool: "codex", session: "other"), clock: clock),
        approved: "Take this Acme task")
      #expect(
        throws: TaskError.claimed(
          "AC-1", holder: TaskServiceTests.agent.description, minutes: 0, human: false)
      ) {
        _ = try other.block("AC-1", TaskBlockTests.input())
      }
      clock.advance(milliseconds: 7_200_000)
      _ = try other.block("AC-1", TaskBlockTests.input(["AC-2"]))
      for steal in [false, true] {
        do {
          _ = try await other.start("AC-1", steal: steal, directory: home)
          Issue.record("Started blocked work")
        } catch let error as TaskError {
          #expect(error.code == .blocked && error.code.exitCode == 6)
          #expect(error.message.contains("task:AC-2") && !error.message.contains("Acme answer"))
          #expect(error.next == ["silta task ls --status todo"])
        }
      }
      _ = try await service.close("AC-2", result: "Acme done", directory: home)
      do {
        _ = try await service.start("AC-1", directory: home)
        Issue.record("Started ready but blocked work")
      } catch let error as TaskError { #expect(error.next == ["silta task unblock AC-1"]) }
      try service.environment.db.write { tx in
        try tx.database.execute(
          sql: "UPDATE task SET claimed_by=?,claimed_at=? WHERE seq=1",
          arguments: [TaskServiceTests.agent.description, TaskService.timestamp(clock.now())])
      }
      #expect(throws: TaskError.self) { _ = try other.unblock(["AC-1"]) }
      try Self.promotionNeedsUnblockThenFreezes(service)
      let git = try #require(service.environment.git as? ScriptedGitRunner)
      #expect(git.requests.isEmpty)
    }
  }

  private static func promotionNeedsUnblockThenFreezes(_ service: TaskService) throws {
    #expect(throws: TaskError.blockedPromotion("AC-1", ready: true)) {
      _ = try service.promote("AC-1", external: "ado:42")
    }
    _ = try service.unblock(["AC-1"])
    _ = try service.promote("AC-1", external: "ado:42")
    for write in [
      { _ = try service.block("AC-1", TaskBlockTests.input()) },
      { _ = try service.unblock(["AC-1"]) },
    ] {
      #expect(throws: TaskError.promoted("AC-1", external: "ado:42"), performing: write)
    }
  }

  @Test func startRechecksWaitingAfterGit() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let dbHome = home.appending(path: "db")
      let blocking = TaskService(environment: try TaskServiceTests.environment(dbHome))
      let git = ScriptedGitRunner(
        script: TaskGitTests.script(repo: repo, cwd: repo, completion: false),
        beforeRequest: { request in
          if request.arguments == ["rev-parse", "--abbrev-ref", "HEAD"] {
            _ = try blocking.block("AC-1", TaskBlockTests.input(["ext:acme"]))
          }
        })
      let env = try TaskServiceTests.environment(dbHome, git: git)
      try TaskGitTests.configure(env, repo: repo)
      let service = TaskService(environment: env)
      var draft = TaskDraft(title: "Acme")
      draft.app = "api"
      _ = try await service.add(draft, directory: home)
      var batch = TaskTriage()
      batch.accept = ["AC-1"]
      _ = try TaskService(environment: env, approved: "Accept Acme").triage(batch)
      do {
        _ = try await service.start("AC-1", directory: repo)
        Issue.record("Interleaving block ignored")
      } catch let error as TaskError {
        #expect(error.code == .blocked && error.message.contains("ext:acme"))
        #expect(error.next == ["silta task ls --status todo"])
      }
      #expect(try service.show("AC-1").status == "blocked")
      #expect(git.isExhausted)
    }
  }

  @Test func secretPolicyAndSafePresentationWithRetainedStorage() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, count: 3, directory: home)
      let secret = "Pwd=" + "acme-secret"
      var input = TaskBlockTests.input(
        ["ext:acme", "url:https://example.com/?" + secret], why: secret)
      let redacted = try service.block("AC-1", input)
      #expect(redacted.warnings.map(\.code).contains("secret_redacted"))
      #expect(redacted.waiting?.why == "[REDACTED:password]")
      input.allowSecret = true
      let agent = TaskService(environment: service.environment)
      #expect(throws: ActorError.self) { _ = try agent.block("AC-2", input) }
      let human = TaskService(
        environment: try TaskServiceTests.environment(home, actor: TaskServiceTests.human()))
      input.allowSecret = false
      #expect(throws: SecretError.self) { _ = try human.block("AC-2", input) }
      input.allowSecret = true
      _ = try service.block("AC-2", input)
      _ = try service.block("AC-3", TaskBlockTests.input())
      let task = try service.show("AC-2", timeline: true)
      let json = try #require(String(bytes: try JSONEncoder().encode(task), encoding: .utf8))
      #expect(!json.contains("acme-secret") && json.contains("REDACTED"))
      var filter = TaskFilter()
      filter.on = "url:https://example.com/?" + secret
      #expect(try service.list(filter).map(\.ref) == ["AC-2"])
      let before = try TaskOrganizationTests.counts(service)[2]
      #expect(throws: ActorError.self) {
        _ = try agent.unblock(["AC-2"], why: secret, allowSecret: true)
      }
      _ = try service.unblock(["AC-2", "AC-3"], why: secret, allowSecret: true)
      #expect(try TaskOrganizationTests.counts(service)[2] == before + 1)
      #expect(
        try service.show("AC-2", timeline: true).timeline?.last?.body == "[REDACTED:password]")
      try service.environment.db.read { db in
        let body = try #require(
          try String.fetchOne(
            db, sql: "SELECT body FROM task_event WHERE kind='block' AND task_id=2"))
        #expect(body.contains("acme-secret"))
        #expect(
          try String.fetchOne(
            db, sql: "SELECT body FROM task_event WHERE kind='unblock' AND task_id=2") == secret)
        let commands = try String.fetchAll(db, sql: "SELECT command FROM approval")
        #expect(
          commands.count == 2
            && commands.allSatisfy { !$0.contains("acme-secret") && $0.contains("--allow-secret") })
      }
    }
  }
}
