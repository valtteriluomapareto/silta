import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskEditTests {
  @Test func documentRoundTripAndOnlyOwnedFieldsChange() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      try service.environment.db.write { tx in
        try tx.database.execute(
          sql: "ALTER TABLE task ADD COLUMN future TEXT DEFAULT 'Acme future'")
        try tx.database.execute(
          sql: "UPDATE task SET acceptance_md='Keep Acme acceptance',future='Acme retained'")
      }
      let initial = try service.show("AC-1")
      var document = TaskEditDocument(initial)
      document.title = "Acme\né"
      document.description = "## Plan\n~~~\n```swift\nAcme\n```\n~~~~~\n"
      document.plan = "- [ ] Acme\n\n"
      document.result = "Acme result\n"
      try Self.checkDocument(document, initial: initial)
      let agent = TaskService(environment: service.environment)
      let result = try agent.edit("AC-1") { _ in document.render() }
      #expect(!result.approvalUsed)
      let edited = try agent.show("AC-1")
      #expect(TaskEditDocument(edited) == document)
      #expect(edited.planRev == 1)
      #expect(edited.acceptance == "Keep Acme acceptance")
      #expect(try TaskOrganizationTests.counts(agent)[2] == 0)
      try service.environment.db.read { db in
        let future = try String.fetchOne(db, sql: "SELECT future FROM task")
        #expect(future == "Acme retained")
      }
      let before = try TaskOrganizationTests.counts(agent)
      _ = try agent.edit("AC-1") { $0 }
      _ = try agent.edit("AC-1") { _ in nil }
      #expect(try TaskOrganizationTests.counts(agent) == before)
      document.description = "Acme changed only description"
      _ = try agent.edit("AC-1") { _ in document.render() }
      #expect(try agent.show("AC-1").planRev == 1)
    }
  }

  private static func checkDocument(_ document: TaskEditDocument, initial: TaskDetails) throws {
    #expect(try TaskEditDocument.parse(document.render(), from: initial) == document)
    let crlf = document.render().replacingOccurrences(of: "\n", with: "\r\n")
    #expect(
      try TaskEditDocument.parse(crlf, from: initial).description
        == document.description.replacingOccurrences(of: "\n", with: "\r\n"))
    let simple = TaskEditDocument(initial).render().replacingOccurrences(of: "~~~", with: "```")
    #expect(throws: TaskError.self) { _ = try TaskEditDocument.parse(simple, from: initial) }
    var blank = document
    blank.title = "  "
    for invalid in [
      blank.render(),
      document.render().replacingOccurrences(of: "~~~~~~", with: "~"),
      document.render().replacingOccurrences(of: "~~~~~~", with: "```"),
      String(document.render().dropLast(8)),
    ] {
      #expect(throws: TaskError.self) { _ = try TaskEditDocument.parse(invalid, from: initial) }
    }
    for invalid in [
      "", "## Title\nAcme", document.render() + "Unexpected",
      document.render().replacingOccurrences(of: "## Acceptance", with: "## Unknown"),
    ] {
      #expect(throws: TaskError.self) { _ = try TaskEditDocument.parse(invalid, from: initial) }
    }
  }

  @Test func editRefusesTickClaimLossPromotionAndStaleFields() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      _ = try service.plan("AC-1", text: "- [ ] Acme")
      let agent = TaskService(environment: service.environment)
      #expect(throws: TaskError.edited("AC-1")) {
        _ = try agent.edit("AC-1") { original in
          _ = try agent.tick("AC-1", step: 1, done: true)
          return original.replacingOccurrences(
            of: "## Title\n~~~\nAcme", with: "## Title\n~~~\nChanged")
        }
      }
      #expect(try agent.show("AC-1").plan == "- [x] Acme")
      #expect(throws: ActorError.self) {
        _ = try agent.edit("AC-1") { original in
          try service.environment.db.write { tx in
            try tx.database.execute(sql: "UPDATE task SET claimed_by=NULL,claimed_at=NULL")
          }
          return original
        }
      }
      var invoked = false
      #expect(throws: ActorError.self) {
        _ = try agent.edit("AC-1") { original in
          invoked = true
          return original
        }
      }
      #expect(!invoked)
      _ = try await agent.start("AC-1", directory: home)
      #expect(throws: TaskError.edited("AC-1")) {
        _ = try agent.edit("AC-1") { original in
          try service.environment.db.write { tx in
            try tx.database.execute(sql: "UPDATE task SET acceptance_md='Other writer'")
          }
          return original
        }
      }
      #expect(throws: TaskError.promoted("AC-1", external: "ado:42")) {
        _ = try agent.edit("AC-1") { original in
          _ = try service.promote("AC-1", external: "ado:42")
          return original
        }
      }
      #expect(try service.show("AC-1").title == "Acme")
      #expect(try TaskOrganizationTests.counts(service)[2] == 1)
    }
  }

  @Test func editApprovalSecretPolicyAndNullableResult() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, directory: home)
      let before = try service.show("AC-1")
      #expect(before.result == nil)
      _ = try service.edit("AC-1") { original in
        original.replacingOccurrences(of: "Acme\n", with: "Acme changed\n")
      }
      #expect(try service.show("AC-1").result == nil)
      #expect(try TaskOrganizationTests.counts(service)[2] == 1)
      let snapshot = try TaskOrganizationTests.counts(service)
      #expect(throws: TaskError.self) { _ = try service.edit("AC-1") { _ in "invalid" } }
      #expect(try TaskOrganizationTests.counts(service) == snapshot)
      var document = TaskEditDocument(try service.show("AC-1"))
      document.acceptance = ("Pwd=" + "acme-secret")
      let redacted = try service.edit("AC-1") { _ in document.render() }
      #expect(redacted.result.warnings.map(\.code) == ["secret_redacted"])
      #expect(try service.show("AC-1").acceptance == "[REDACTED:password]")
      _ = try service.edit("AC-1", allowSecret: true) { _ in document.render() }
      #expect(try service.show("AC-1").acceptance == ("Pwd=" + "acme-secret"))
      let human = TaskService(
        environment: try TaskServiceTests.environment(
          home,
          actor: TaskServiceTests.human()))
      document.title += " changed"
      #expect(throws: SecretError.self) {
        _ = try human.edit("AC-1") { _ in document.render() }
      }
    }
  }
}
