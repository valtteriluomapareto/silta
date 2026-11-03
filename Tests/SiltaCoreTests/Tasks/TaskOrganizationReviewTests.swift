import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskOrganizationReviewTests {
  @Test(arguments: [false, true]) func unchangedApprovedSecretIsARead(human: Bool) async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let service = try TaskOrganizationTests.service(home, clock: clock)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      let secret = "Pwd=" + "acme-secret"
      _ = try service.plan("AC-1", text: secret, allowSecret: true)
      let before = try service.show("AC-1")
      let counts = try TaskOrganizationTests.counts(service)
      let day = try service.environment.db.read {
        try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='last_backup_day'")
      }
      clock.advance(milliseconds: 86_400_000)
      let actor = try human ? TaskServiceTests.human() : TaskServiceTests.agent
      let editor = TaskService(
        environment: try TaskServiceTests.environment(
          home,
          actor: actor, clock: clock))
      _ = try editor.edit("AC-1") { $0 }
      let after = try service.show("AC-1")
      #expect(after.plan == secret)
      #expect(after.planRev == before.planRev)
      #expect(after.claimedAt == before.claimedAt)
      #expect(try TaskOrganizationTests.counts(service) == counts)
      let afterDay = try service.environment.db.read {
        try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='last_backup_day'")
      }
      #expect(afterDay == day)
    }
  }

  @Test func planNamedAppsUseBothCodeForms() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      try TaskLinkTests.seed(service)
      try service.environment.db.write { tx in
        for slug in ["planning-api", "plan"] {
          try tx.database.execute(
            sql: """
              INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref)
              VALUES(?,1,?,'Acme',1,?)
              """, arguments: [slug, slug, slug])
        }
      }
      for target in ["planning-api:src/Acme.swift#L1", "plan@feature/acme:src/Acme.swift"] {
        _ = try service.link("AC-1", target: target)
        _ = try service.link("AC-1", target: "code:" + target)
      }
      #expect(try service.show("AC-1").links.count == 2)
    }
  }

  @Test func historicalEmptyPlanHasNoLineOne() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      _ = try service.plan("AC-1", text: "")
      #expect(throws: TaskError.self) { _ = try service.link("AC-1", target: "plan@1#L1") }
      #expect(try service.show("AC-1").links.isEmpty)
    }
  }

  @Test func secretLinkRecoveryUsesAnExistingOption() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, directory: home)
      let human = TaskService(
        environment: try TaskServiceTests.environment(
          home,
          actor: TaskServiceTests.human()))
      let target = "url:https://example.com/acme?" + "sig=" + "acme-secret"
      do {
        _ = try human.link("AC-1", target: target)
        Issue.record("Expected secret refusal")
      } catch let error as any CodedError {
        #expect(error.code == .invalid)
        #expect(error.next == ["silta task link --help"])
        #expect(!error.message.contains("acme-secret"))
      }
    }
  }

  @Test func validatedEditApprovalIsUsedOnCancelAndNoop() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, directory: home)
      let before = try TaskOrganizationTests.counts(service)
      #expect(try service.edit("AC-1") { _ in nil }.approvalUsed)
      #expect(try service.edit("AC-1") { $0 }.approvalUsed)
      #expect(try TaskOrganizationTests.counts(service) == before)
    }
  }
}
