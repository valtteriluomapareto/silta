import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocProposalServiceTests {
  static func service(_ home: URL, _ store: DatabaseStore, human: Bool = false) throws
    -> DocProposalService
  {
    let edit = try DocWritePolicyTests.service(home, store, human: human, approved: nil)
    return DocProposalService(environment: edit.environment, workspace: "acme", approved: nil)
  }

  static func request(_ slug: String = "rules") -> DocProposalRequest {
    DocProposalRequest(slug: slug, title: "Rules", about: ["service:push"], why: "Share the rule.")
  }

  static func row(_ store: DatabaseStore, revision: Int? = nil) throws -> Row {
    try store.read { db in
      try #require(
        try Row.fetchOne(
          db, sql: "SELECT * FROM doc_rev WHERE rev=? ORDER BY id DESC",
          arguments: [revision ?? 1]))
    }
  }

  static func refusal(_ code: ErrorCode, _ operation: () throws -> Void) -> (any CodedError)? {
    do {
      try operation()
      Issue.record("Forbidden proposal succeeded")
    } catch let error as any CodedError {
      #expect(error.code == code)
      return error
    } catch { Issue.record("Expected coded proposal refusal: \(error)") }
    return nil
  }

  static func task(
    _ store: DatabaseStore, seq: Int64, workspace: Int64 = 1,
    actor: String = DocStoreTests.actor.description, status: String = "doing", age: TimeInterval = 0
  ) throws {
    let stamp = utcTimestamp(AcmeDocAttachments.instant.addingTimeInterval(-age))
    try store.write {
      try $0.database.execute(
        sql: """
          INSERT INTO task(uid,workspace_id,seq,title,status,claimed_by,claimed_at,
            created_by,created_at,updated_at) VALUES(?,?,?,'Acme task',?,?,?,?,?,?)
          """,
        arguments: [
          "task-\(workspace)-\(seq)", workspace, seq, status, actor, stamp, actor, stamp, stamp,
        ])
    }
  }

  @Test(arguments: [String?.none, "1"])
  func proposalDefaultsMetadataToCurrentAcceptedEvenWithHistoricalBase(base: String?) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try DocWritePolicyTests.seed(store)
      var current = DocDraft(slug: "rules", body: "Current body")
      current.title = "Current title"
      current.kind = "flow"
      current.about = ["app:api"]
      _ = try DocStoreTests.accept(current, in: store, ids: SeededIDGenerator(seed: 83))
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET title=NULL,kind=NULL,about_refs=NULL WHERE rev=1")
      }
      let before = try DocStoreTests.snapshot(store)
      let result = try Self.service(home, store).propose(
        DocProposalRequest(slug: "doc:rules", base: base, why: "Share current knowledge."),
        input: { "Proposed body" })
      #expect(result.ref == "doc:rules@3")
      let row = try Self.row(store, revision: 3)
      #expect(
        row["state"] as String == "proposed" && row["base_rev"] as Int == (base == nil ? 2 : 1))
      #expect(row["title"] as String == "Current title" && row["kind"] as String == "flow")
      #expect(row["about_refs"] as String == "[\"app:api\"]")
      #expect(
        row["body_md"] as String == "Proposed body"
          && row["message"] as String == "Share current knowledge.")
      let after = try DocStoreTests.snapshot(store)
      #expect(before[0] == after[0] && before[2] == after[2] && before[3] == after[3])
      #expect(row["triaged_at"] as String? == nil && row["triaged_by"] as String? == nil)
    }
  }

  @Test(arguments: [false, true])
  func newAndPendingOnlyReportAllMissingFlagsBeforeInput(pending: Bool) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      if pending {
        try AcmeDocAttachments.attach("rules", to: "service", in: store, state: "proposed")
      }
      let service = try Self.service(home, store)
      let before = try DocVerificationPreparationTests.truth(store)
      let error = try #require(
        Self.refusal(.usage) {
          _ = try service.propose(DocProposalRequest(slug: "rules")) {
            Issue.record("Input read before required metadata")
            return "Body"
          }
        })
      #expect(["-m", "--title", "--about"].allSatisfy(error.message.contains))
      let missing = try #require(
        Self.refusal(.usage) {
          _ = try service.propose(DocProposalRequest(slug: "rules"), input: nil)
        })
      if !pending {
        let text = OutputRouter.render(.failure(missing), mode: OutputMode(json: false))
        let json = OutputRouter.render(.failure(missing), mode: OutputMode(json: true))
        Golden.forTests().check(text.stderr + json.stdout, "doc-proposal-missing.txt")
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test(arguments: [false, true])
  func everyCallerAndApprovalSubmitsPendingWithoutLiveProjection(human: Bool) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE workspace SET settings=json_set(settings,'$.proposals','ask')")
      }
      var service = try Self.service(home, store, human: human)
      for (index, approval) in ([nil, "Capture it", "<the human's words>"] as [String?])
        .enumerated()
      {
        service.approved = approval
        let result = try service.propose(Self.request("rules-\(index)"), input: { "Shared body" })
        #expect(result.warnings.map(\.code) == (approval == nil ? [] : ["approval_unused"]))
      }
      try store.read { (db: Database) throws in
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev WHERE state='proposed'") == 3)
        for table in ["link", "doc_verification", "approval"] {
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0)
        }
        #expect(
          try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM doc WHERE current_rev IS NOT NULL OR verified_at IS NOT NULL"
          ) == 0)
      }
      try AcmeDocAttachments.apply(AcmeDocAttachments.yaml(removing: "service"), to: store)
    }
  }

  @Test(arguments: [0, 1, 2])
  func freshClaimsChooseNullOneOrExplicitTaskRecovery(count: Int) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try Self.task(store, seq: 90, actor: "agent:codex:other")
      try Self.task(store, seq: 91, age: TaskService.claimDuration)
      try Self.task(store, seq: 92, status: "review")
      try store.write {
        try $0.database.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE')")
      }
      try Self.task(store, seq: 1, workspace: 2)
      for index in 0..<count { try Self.task(store, seq: Int64(index + 1), age: 0.001) }
      let service = try Self.service(home, store)
      if count == 2 {
        let error = try #require(
          Self.refusal(.usage) { _ = try service.propose(Self.request(), input: { "Body" }) })
        #expect(error.next.joined().contains("--task"))
      } else {
        _ = try service.propose(Self.request(), input: { "Body" })
        let source: Int64? = try Self.row(store)["source_task_id"]
        let expected = try store.read {
          try Int64.fetchOne($0, sql: "SELECT id FROM task WHERE uid='task-1-1'")
        }
        #expect(source == (count == 0 ? nil : expected))
      }
    }
  }

  @Test func sourceRecheckUsesTheCapturedClockInstant() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try Self.task(store, seq: 1)
      let service = try Self.service(home, store)
      let clock = try #require(service.environment.clock as? FakeClock)
      _ = try service.propose(Self.request()) {
        clock.advance(milliseconds: 10_800_000)
        return "Body"
      }
      #expect(try Self.row(store)["source_task_id"] as Int64? != nil)
    }
  }

  @Test func explicitSourceUsesOwnedUIDWithoutRequiringFreshClaim() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try Self.task(store, seq: 1, status: "dropped", age: 999_999)
      var request = Self.request()
      request.task = "AC-1"
      let service = try Self.service(home, store)
      _ = try service.propose(request, input: { "Body" })
      #expect(try Self.row(store)["source_task_id"] as Int64? != nil)
      request.task = "BE-1"
      _ = Self.refusal(.invalid) {
        _ = try service.propose(request) {
          Issue.record("Foreign source read input")
          return "Body"
        }
      }
    }
  }

  @Test(arguments: ["0", "-1", "wrong", "2", "99"])
  func explicitBaseRequiresOwnedAcceptedHistory(base: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try DocWritePolicyTests.seed(store)
      try store.write {
        try $0.database.execute(
          sql:
            "INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at) VALUES('pending',1,2,'Pending','proposed','human:acme','')"
        )
      }
      var foreign = DocDraft(slug: "other", body: "Other document")
      foreign.title = "Other"
      foreign.about = ["service:push"]
      _ = try DocStoreTests.accept(foreign, in: store, ids: SeededIDGenerator(seed: 93))
      try store.write {
        try $0.database.execute(
          sql:
            "UPDATE doc_rev SET rev=99 WHERE doc_id=(SELECT id FROM doc WHERE slug='other'); UPDATE doc SET current_rev=99 WHERE slug='other'"
        )
      }
      let before = try DocVerificationPreparationTests.truth(store)
      let request = DocProposalRequest(slug: "rules", base: base, why: "Why")
      _ = Self.refusal(base == "99" ? .notFound : .invalid) {
        _ = try Self.service(home, store).propose(request) {
          Issue.record("Invalid base read input")
          return "Body"
        }
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test(arguments: [
    "pointer", "target", "base", "doc", "workspace", "claim", "heartbeat", "claim-count",
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
        "base": "UPDATE doc_rev SET uid='changed-base' WHERE rev=1",
        "doc": "UPDATE doc SET uid='changed-doc'",
        "workspace": "UPDATE workspace SET uid='changed-workspace'",
        "claim": "UPDATE task SET claimed_by='agent:codex:other'",
        "heartbeat": "UPDATE task SET claimed_at='2023-11-14T22:13:20.001Z'",
        "explicit-source": "UPDATE task SET uid='changed-task'",
      ]
      var request = DocProposalRequest(slug: "rules", base: "1", why: "Why")
      if change == "explicit-source" { request.task = "AC-1" }
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

  @Test(arguments: ["oversize", "redaction", "counter", "insert"])
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
              "CREATE TRIGGER reject_proposal BEFORE INSERT ON doc_rev BEGIN SELECT RAISE(ABORT,'reject'); END"
          )
        }
      }
      let before = try DocVerificationPreparationTests.truth(store)
      let body =
        failure == "redaction"
        ? "Pwd=x " + String(repeating: ".", count: 65_530)
        : String(repeating: ".", count: failure == "oversize" ? 65_537 : 65_536)
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
}
