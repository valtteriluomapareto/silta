import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension DocProposalServiceTests {
  @Test(arguments: [false, true])
  func suppliedSecretsRefuseHumanAndRedactAgent(human: Bool) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      var request = Self.request()
      request.title = DocWritePolicyTests.secret
      request.why = DocWritePolicyTests.secret
      let service = try Self.service(home, store, human: human)
      if human {
        _ = Self.refusal(.invalid) {
          _ = try service.propose(request, input: { DocWritePolicyTests.secret })
        }
      } else {
        let result = try service.propose(request, input: { DocWritePolicyTests.secret })
        #expect(result.warnings.contains(SecretGuard.warning))
        let row = try Self.row(store)
        for field in ["title", "body_md", "message"] {
          #expect(row[field] as String == "[REDACTED:password]")
        }
      }
    }
  }

  @Test func ownedLegacyMetadataAndContentRemainLiteral() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try DocWritePolicyTests.seed(store, body: DocWritePolicyTests.secret)
      let title = "Legacy\n" + String(repeating: "é", count: 140) + DocWritePolicyTests.secret
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc SET title=?,kind='legacy label'", arguments: [title])
        try $0.database.execute(
          sql: "UPDATE doc_rev SET title=?,kind='legacy label' WHERE rev=1", arguments: [title])
      }
      let service = try Self.service(home, store)
      _ = try service.propose(
        DocProposalRequest(slug: "rules", why: "Why"), input: { DocWritePolicyTests.secret })
      let row = try Self.row(store, revision: 2)
      #expect((row["title"] as String).utf8.elementsEqual(title.utf8))
      #expect(
        row["kind"] as String == "legacy label"
          && row["body_md"] as String == DocWritePolicyTests.secret)
      let unchanged = try service.propose(
        DocProposalRequest(slug: "rules", title: title, why: "Why"),
        input: { DocWritePolicyTests.secret })
      #expect(unchanged.ref == "doc:rules@3" && unchanged.warnings.isEmpty)
      var changed = DocProposalRequest(slug: "rules", title: title + " changed", why: "Why")
      _ = Self.refusal(.invalid) { _ = try service.propose(changed, input: { "Safe" }) }
      changed.title = "Valid"
      changed.about = ["service:Password%3Dprivate123"]
      _ = Self.refusal(.invalid) { _ = try service.propose(changed, input: { "Safe" }) }
    }
  }

  @Test func suppliedBodyAtLimitHonorsRetainedReservations() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try AcmeDocAttachments.attach("rules", to: "service", in: store, state: "proposed")
      try store.write {
        try $0.database.execute(
          sql: "DELETE FROM link; INSERT INTO seq_counter(scope,next) VALUES('doc_rev:1:rules',20)")
      }
      let result = try Self.service(home, store).propose(
        Self.request(), input: { String(repeating: ".", count: 65_536) })
      #expect(result.ref == "doc:rules@20")
      let row = try Self.row(store, revision: 20)
      #expect((row["body_md"] as String).utf8.count == 65_536)
      #expect(row["base_rev"] as Int? == nil && row["kind"] as String == "runbook")
    }
  }

  @Test(arguments: ["acme", DocWritePolicyTests.credential])
  func unsafeNewIdentityAndScopeUseProtectedHubs(scope: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      var service = try Self.service(home, store)
      service.workspace = scope
      let before = try DocVerificationPreparationTests.truth(store)
      let error = try #require(
        Self.refusal(scope == "acme" ? .invalid : .notFound) {
          _ = try service.propose(Self.request(DocWritePolicyTests.credential)) {
            Issue.record("Unsafe identity read input")
            return "Body"
          }
        })
      #expect(error.next == [scope == "acme" ? "silta --ws 'acme' doc ls" : "silta ws ls"])
      #expect(!error.message.contains(DocWritePolicyTests.credential))
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test(arguments: ["oversize", "redaction", "redaction-shrink", "counter", "insert"])
  func boundsAndLateFailuresWriteNothing(failure: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      if failure == "counter" {
        try store.write {
          try $0.database.execute(
            sql: "INSERT INTO seq_counter(scope,next) VALUES('doc_rev:1:rules',?)",
            arguments: [Int64.max])
        }
      } else if failure == "insert" {
        try store.write {
          try $0.database.execute(
            sql:
              """
              CREATE TRIGGER reject_proposal BEFORE INSERT ON doc_rev
              BEGIN SELECT RAISE(ABORT,'reject'); END
              """
          )
        }
      }
      let before = try DocVerificationPreparationTests.truth(store)
      let body: String
      switch failure {
      case "redaction": body = "Pwd=x " + String(repeating: ".", count: 65_530)
      case "redaction-shrink": body = "Pwd=" + String(repeating: "x", count: 65_533)
      default: body = String(repeating: ".", count: failure == "oversize" ? 65_537 : 65_536)
      }
      if failure == "redaction-shrink" {
        #expect(body.utf8.count > DocInput.maximumBytes)
        #expect(SecretGuard.redacted(body).utf8.count < DocInput.maximumBytes)
      }
      if failure == "counter" || failure == "insert" {
        #expect(
          throws: failure == "counter" ? StorageError.resourceExhausted : .constraintViolation
        ) {
          _ = try Self.service(home, store).propose(Self.request(), input: { body })
        }
      } else {
        _ = Self.refusal(.invalid) {
          _ = try Self.service(home, store).propose(Self.request(), input: { body })
        }
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }
  @Test(arguments: [
    "pointer", "target", "new-target", "base", "doc", "workspace", "claim", "heartbeat",
    "claim-count",
    "explicit-source",
  ])
  func changedBaselineBindingOrSourceRollsBack(change: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try DocWritePolicyTests.seed(store)
      try DocWritePolicyTests.seed(store, seed: 83)
      try Self.task(store, seq: 1)
      let statements = [
        "pointer": "UPDATE doc SET current_rev=1",
        "target": "UPDATE service SET uid='changed-service'",
        "new-target": "UPDATE app SET uid='changed-app'",
        "base": "UPDATE doc_rev SET uid='changed-base' WHERE rev=1",
        "doc": "UPDATE doc SET uid='changed-doc'",
        "workspace": "UPDATE workspace SET uid='changed-workspace'",
        "claim": "UPDATE task SET claimed_by='agent:codex:other'",
        "heartbeat": "UPDATE task SET claimed_at='2023-11-14T22:13:20.001Z'",
        "explicit-source": "UPDATE task SET uid='changed-task'",
      ]
      var request = DocProposalRequest(slug: "rules", base: "1", why: "Why")
      if change == "explicit-source" { request.task = "AC-1" }
      if change == "new-target" { request.about = ["app:api"] }
      var committed: [[String]] = []
      _ = Self.refusal(.conflict) {
        _ = try Self.service(home, store).propose(request) {
          if change == "claim-count" {
            try Self.task(store, seq: 2)
          } else if let sql = statements[change] {
            try store.write { try $0.database.execute(sql: sql) }
          }
          committed = try DocVerificationPreparationTests.truth(store)
          return "Proposed body"
        }
      }
      #expect(!committed.isEmpty)
      #expect(try DocVerificationPreparationTests.truth(store) == committed)
    }
  }

}
