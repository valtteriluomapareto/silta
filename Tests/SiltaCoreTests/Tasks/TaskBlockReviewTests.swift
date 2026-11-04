import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskBlockReviewTests {
  @Test func namedBlockRecoveryPreservesTargetsAndDay() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, count: 2, directory: home)
      let agent = TaskService(environment: service.environment)
      var input = TaskBlockTests.input(["AC-2", "ext:acme"])
      input.followUp = "3d"
      input.allowSecret = true
      do {
        _ = try agent.block("AC-1", input)
        Issue.record("Approval missing")
      } catch let error as ActorError {
        let retry = error.next.joined()
        #expect(retry.contains("--on 'AC-2'"))
        #expect(retry.contains("'ext:acme'"))
        #expect(retry.contains("--follow-up '3d'"))
        #expect(!retry.contains("Acme answer"))
      }
    }
  }

  @Test func linkOrderAndUIDAssignmentFollowInputOrder() async throws {
    try await withScratchDirectory { home in
      let seed = TaskServiceTests.agentSeed
      let service = try TaskOrganizationTests.service(home, seed: seed)
      try await TaskBlockTests.add(service, directory: home)
      let refs = (0..<12).map { "ext:acme-\($0)" }
      _ = try service.block("AC-1", TaskBlockTests.input(refs + [refs[0]]))
      let details = try service.show("AC-1")
      #expect(details.links.map(\.target) == refs)
      let expected = SeededIDGenerator(seed: seed)
      _ = try expected.next(at: TaskServiceTests.now)
      let uids = try refs.map { _ in try expected.next(at: TaskServiceTests.now) }
      try service.environment.db.read { db in
        let rows = try Row.fetchAll(db, sql: "SELECT to_ext,uid FROM link ORDER BY id")
        #expect(rows.map { "ext:" + ($0["to_ext"] as String) } == refs)
        #expect(rows.map { $0["uid"] as String } == uids)
      }
    }
  }

  @Test func reasonOnlySecretPolicyProtectsPersistedEvent() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, directory: home)
      let secret = "Pwd=" + "acme-secret"
      let result = try service.block("AC-1", TaskBlockTests.input(why: secret))
      #expect(result.warnings.map(\.code) == ["secret_redacted"])
      try service.environment.db.read { db in
        let raw = try #require(
          try String.fetchOne(db, sql: "SELECT body FROM task_event WHERE kind='block'"))
        #expect(try TaskBlockEvent.decode(raw).why == "[REDACTED:password]")
      }
      _ = try service.unblock(["AC-1"])
      let human = TaskService(
        environment: try TaskServiceTests.environment(home, actor: TaskServiceTests.human()))
      #expect(throws: SecretError.self) {
        _ = try human.block("AC-1", TaskBlockTests.input(why: secret))
      }
    }
  }
  @Test func taskFilterIdentityAndEmptyBacklogValidation() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      var filter = TaskFilter()
      filter.on = "bad"
      #expect(throws: TaskError.self) { _ = try service.list(filter) }
      try await TaskBlockTests.add(service, count: 3, directory: home)
      _ = try service.block("AC-1", TaskBlockTests.input(["AC-2"]))
      filter.on = "AC-3"
      #expect(try service.list(filter).isEmpty)
      filter.on = "AC-2"
      #expect(try service.list(filter).map(\.ref) == ["AC-1"])
    }
  }

  @Test func unblockSecretPolicyProtectsPersistedReason() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, directory: home)
      _ = try service.block("AC-1", TaskBlockTests.input())
      let secret = "Pwd=" + "acme-secret"
      let human = TaskService(
        environment: try TaskServiceTests.environment(home, actor: TaskServiceTests.human()))
      #expect(throws: SecretError.self) { _ = try human.unblock(["AC-1"], why: secret) }
      let result = try service.unblock(["AC-1"], why: secret).tasks
      #expect(result.first?.warnings.map(\.code) == ["secret_redacted"])
      try service.environment.db.read { db in
        let body = try String.fetchOne(db, sql: "SELECT body FROM task_event WHERE kind='unblock'")
        #expect(body == "[REDACTED:password]")
      }
    }
  }

}

struct TaskBlockRecoveryPrivacyTests {
  @Test func safeRetryKeepsIdentifiersAndRequiresURLReplacement() {
    let party = "ext:" + String(repeating: "a", count: 52)
    let secret = "Pwd=" + "acme-secret"
    var input = TaskBlockTests.input([
      party, "url:https://example.com/?" + secret,
      "url:https://example.com/acme", "task:AC-2",
    ])
    input.followUp = "3d"
    let command = input.command("AC-1")
    #expect(command.contains("--on '" + party + "'"))
    #expect(command.contains("--on '<blocker-ref>'"))
    #expect(command.contains("--on 'url:https://example.com/acme'"))
    #expect(command.contains("--on 'task:AC-2'"))
    #expect(command.contains("--follow-up '3d'"))
    #expect(!command.contains("acme-secret") && !command.contains("REDACTED"))
    #expect(!input.command(secret).contains("acme-secret"))
  }
}
