import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskOrganizationGuardTests {
  @Test func claimsRefuseBeforeInputAndEveryOrganizationWrite() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      let other = TaskService(
        environment: try TaskServiceTests.environment(
          home,
          actor: .agent(tool: "codex", session: "other")), approved: "Organize this Acme task")
      let failure = TaskError.claimed(
        "AC-1", holder: TaskServiceTests.agent.description, minutes: 0)
      var called = false
      #expect(throws: failure) {
        _ = try other.edit("AC-1") { text in
          called = true
          return text
        }
      }
      #expect(!called)
      #expect(throws: failure) { _ = try other.archive("AC-1") }
      #expect(throws: failure) { _ = try other.link("AC-1", target: "url:https://example.com") }
      #expect(throws: failure) { _ = try other.promote("AC-1", external: "ado:42") }
      let at = TaskServiceTests.now.addingTimeInterval(120)
      let clock = FakeClock(now: at)
      let owner = TaskService(environment: try TaskServiceTests.environment(home, clock: clock))
      _ = try owner.archive("AC-1", keep: true)
      #expect(try owner.show("AC-1").claimedAt == TaskService.timestamp(at))
      clock.advance(milliseconds: 120_000)
      _ = try owner.link("AC-1", target: "url:https://example.com")
      #expect(try owner.show("AC-1").claimedAt == TaskService.timestamp(clock.now()))
    }
  }

  @Test func sameTextNewRevisionStillConflictsAndClaimRefreshesOnEdit() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let service = try TaskOrganizationTests.service(home, clock: clock)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      _ = try service.plan("AC-1", text: "Acme plan")
      #expect(throws: TaskError.edited("AC-1")) {
        _ = try service.edit("AC-1") { original in
          _ = try service.plan("AC-1", text: "Acme plan")
          return original
        }
      }
      clock.advance(milliseconds: 120_000)
      _ = try service.edit("AC-1") {
        $0.replacingOccurrences(of: "Acme plan", with: "Acme revised")
      }
      #expect(try service.show("AC-1").claimedAt == TaskService.timestamp(clock.now()))
      #expect(try service.show("AC-1").planRev == 3)
      clock.advance(milliseconds: 120_000)
      _ = try service.edit("AC-1") { $0.replacingOccurrences(of: "Acme\n", with: "Acme title\n") }
      #expect(try service.show("AC-1").claimedAt == TaskService.timestamp(clock.now()))
    }
  }

  @Test func editWriteRechecksAFreshClaimAfterChangedInput() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      let other = ActorID.agent(tool: "codex", session: "other")
      #expect(throws: TaskError.claimed("AC-1", holder: other.description, minutes: 0)) {
        _ = try service.edit("AC-1") { original in
          try service.environment.db.write { tx in
            try tx.database.execute(
              sql: "UPDATE task SET claimed_by=?",
              arguments: [other.description])
          }
          return original.replacingOccurrences(of: "Acme", with: "Acme changed")
        }
      }
      #expect(try service.show("AC-1").title == "Acme")
      #expect(try TaskOrganizationTests.counts(service)[2] == 0)
    }
  }

  @Test func batchReferenceErrorsStayOnOneLineAndRedactCredentials() {
    let error = TaskReferenceError(ref: ("AC-1\nPwd=" + "acme-secret"), missing: false)
    #expect(!error.message.contains("\n"))
    #expect(!error.message.contains("acme-secret"))
    #expect(error.message.contains("AC-1"))
    #expect(error.code == .invalid)
    #expect(TaskReferenceError(ref: "AC-404", missing: true).code == .notFound)
  }

  @Test func terminalHumanCanTriageAndPromoteWithoutApprovalRows() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, directory: home)
      let human = TaskService(
        environment: try TaskServiceTests.environment(
          home,
          actor: TaskServiceTests.human()), approved: "<ignored>")
      var batch = TaskTriage()
      batch.accept = ["AC-1"]
      #expect(try human.triage(batch).first?.status == "todo")
      _ = try human.promote("AC-1", external: "jira:ACME-42")
      #expect(try service.show("AC-1").externalRef == "jira:ACME-42")
      #expect(try TaskOrganizationTests.counts(service)[2] == 0)
      let events = try human.show("AC-1", timeline: true).timeline ?? []
      #expect(events.last?.actor == "human:acme")
    }
  }
}
