import Foundation
import GRDB
import SiltaTestSupport
import Synchronization
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocWritePolicyTests {
  static let secret = "Password=private123"
  static let credential = "AKIA" + String(repeating: "A", count: 16)

  static func service(
    _ home: URL, _ store: DatabaseStore, human: Bool = false, approved: String? = "Keep the rules",
    git: any GitRunner = ScriptedGitRunner(script: [])
  ) throws -> DocWriteService {
    let base = try DocVerificationPreparationTests.environment(home, store: store, git: git)
    let env = SiltaEnvironment(
      clock: base.clock, ids: base.ids, git: git, home: base.home, db: store, log: base.log,
      actor: human ? .human(name: "acme") : base.actor)
    return DocWriteService(environment: env, workspace: "acme", approved: approved)
  }

  static func request(_ slug: String = "rules") -> DocEditRequest {
    DocEditRequest(slug: slug, title: "Rules", about: ["service:push"])
  }

  static func seed(_ store: DatabaseStore, body: String = "Original", seed: UInt64 = 82) throws {
    var draft = DocDraft(slug: "rules", body: body)
    draft.title = "Rules"
    draft.about = ["service:push"]
    _ = try DocStoreTests.accept(draft, in: store, ids: SeededIDGenerator(seed: seed))
  }

  static func refusal(_ code: ErrorCode, _ operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("A forbidden document write succeeded")
    } catch let error as any CodedError { #expect(error.code == code) } catch {
      Issue.record("Expected a coded refusal: \(error)")
    }
  }

  @Test func gateBeforeInputOrStorageAndMissingMetadataBeforeInput() async throws {
    try await withScratchDirectory { home in
      let store = DatabaseStore(
        home: home, clock: FakeClock(now: DocStoreTests.instant), jitter: { 0 })
      let service = try Self.service(home, store, approved: nil)
      await Self.refusal(.humanOnly) {
        _ = try await service.edit(Self.request()) {
          Issue.record("Input read before gate")
          return ""
        }
      }
      #expect(!FileManager.default.fileExists(atPath: home.appending(path: "silta.db").path))
      let existing = try AcmeDocAttachments.make(in: home.appending(path: "existing"))
      await Self.refusal(.usage) {
        _ = try await Self.service(home, existing).edit(DocEditRequest(slug: "missing")) {
          Issue.record("Input read before metadata")
          return ""
        }
      }
    }
  }

  @Test func explicitSecretIdentityOverrideAndOwnedKeepBodyRemainLiteral() async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try Self.service(home, store)
      var allowed = Self.request(Self.credential)
      allowed.allowSecret = true
      _ = try await service.edit(allowed) { "Safe" }
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT slug FROM doc") }
          == Self.credential)
      var preserve = DocEditRequest(slug: Self.credential)
      preserve.keepBody = true
      _ = try await service.edit(preserve, input: nil)
    }
  }

  @Test func keptOwnedBodyIsLiteralIncludingArchivedOversizeAndSecret() async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let body = Self.secret + String(repeating: "é", count: 40_000)
      try Self.seed(store, body: body)
      try store.write {
        _ = try DocStoreTests.writer($0, ids: SeededIDGenerator(seed: 89)).archive("rules")
      }
      var request = DocEditRequest(slug: "rules")
      request.keepBody = true
      request.about = ["service:push"]
      let service = try Self.service(home, store)
      let result = try await service.edit(request, input: nil)
      #expect(result.ref == "doc:rules@2")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT body_md FROM doc_rev WHERE rev=2") }
          .map { $0.utf8.elementsEqual(body.utf8) } == true)
      await Self.refusal(.usage) { _ = try await service.edit(request) { "Must not replace" } }
      request.slug = "missing"
      await Self.refusal(.usage) { _ = try await service.edit(request, input: nil) }
    }
  }

  @Test(arguments: [
    "archive", "pointer", "revision", "replacement", "creation", "body", "workspace", "same-body",
  ])
  func fullBaselineRacePreservesCommittedChange(change: String) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      if change != "creation" { try Self.seed(store, body: Self.secret) }
      let sql: [String: String] = [
        "archive": "UPDATE doc SET archived=1",
        "pointer": "UPDATE doc SET current_rev=NULL",
        "revision": "UPDATE doc_rev SET uid='replacement-revision'",
        "replacement": "UPDATE doc SET uid='replacement-doc'",
        "body": "UPDATE doc_rev SET body_md='Committed concurrent body'",
        "workspace": "UPDATE workspace SET uid='replacement-workspace'",
      ]
      var committed: [[String]] = []
      var request = change == "creation" ? Self.request() : DocEditRequest(slug: "rules")
      request.about = ["service:push"]
      await Self.refusal(.conflict) {
        _ = try await Self.service(home, store).edit(request) {
          if change == "creation" || change == "same-body" {
            try Self.seed(store, body: Self.secret, seed: 83)
          } else if let statement = sql[change] {
            try store.write { try $0.database.execute(sql: statement) }
          }
          committed = try DocVerificationPreparationTests.truth(store)
          return Self.secret
        }
      }
      #expect(!committed.isEmpty)
      #expect(try DocVerificationPreparationTests.truth(store) == committed)
    }
  }

  @Test(arguments: ["approval", "approval-change"])
  func lateApprovalFailureRollsBackEverything(failure: String) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try Self.seed(store)
      let trigger = failure == "approval" ? "ON approval" : "ON change_log WHEN NEW.kind='approval'"
      try store.write {
        try $0.database.execute(
          sql:
            "CREATE TRIGGER reject_approval BEFORE INSERT \(trigger) BEGIN SELECT RAISE(ABORT,'reject'); END"
        )
      }
      let before = try DocVerificationPreparationTests.truth(store)
      do {
        _ = try await Self.service(home, store).edit(DocEditRequest(slug: "rules")) { "New" }
        Issue.record("Late approval failure did not roll back")
      } catch { #expect((error as? StorageError) == .constraintViolation) }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test func identicalSaveCreatesRevisionAndExactApprovalWithoutBodyOrTitle() async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try Self.seed(store, body: Self.secret)
      let before =
        try store.read { try Int.fetchOne($0, sql: "SELECT MAX(seq) FROM change_log") } ?? 0
      let result = try await Self.service(home, store, approved: "  Keep \(Self.secret)  ")
        .edit(DocEditRequest(slug: "rules")) { Self.secret }
      #expect(result.ref == "doc:rules@2" && result.warnings.contains(SecretGuard.warning))
      try store.read { db in
        #expect(
          try String.fetchAll(
            db, sql: "SELECT kind FROM change_log WHERE seq>? ORDER BY seq",
            arguments: [before]) == ["doc", "approval"])
        #expect(
          try String.fetchOne(db, sql: "SELECT words FROM approval") == "Keep [REDACTED:password]")
        #expect(
          try String.fetchOne(db, sql: "SELECT actor FROM doc_rev WHERE rev=2")
            == DocStoreTests.actor.description)
        #expect(
          try String.fetchOne(db, sql: "SELECT body_md FROM doc_rev WHERE rev=2") == Self.secret)
        let command = try #require(try String.fetchOne(db, sql: "SELECT command FROM approval"))
        #expect(
          command.contains("-F <file>") && !command.contains(Self.secret)
            && !command.contains("Rules"))
      }
    }
  }

}

extension DocWritePolicyTests {
  @Test(arguments: [false, true])
  func capturedEvidenceOutsideTransactionAndKeptBodyRace(keep: Bool) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      var initial = DocVerificationPreparationTests.draft(["app:api"])
      initial.slug = "rules"
      _ = try DocStoreTests.accept(initial, in: store, ids: SeededIDGenerator(seed: 82))
      let committed = Mutex<[[String]]>([])
      let git = ScriptedGitRunner(
        script: [
          (
            DocVerificationPreparationTests.request("origin/api", repo: repo),
            DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
          )
        ],
        beforeRequest: { _ in
          if keep {
            try store.write {
              try $0.database.execute(
                sql: """
                  UPDATE doc_rev SET uid='new-baseline'
                  WHERE doc_id=(SELECT id FROM doc WHERE slug='rules')
                  """
              )
            }
          } else {
            try store.write { _ in }
          }
          let truth = try DocVerificationPreparationTests.truth(store)
          committed.withLock { $0 = truth }
        })
      var request = DocEditRequest(slug: "rules")
      request.keepBody = keep
      let service = try Self.service(home, store, git: git)
      if keep {
        await Self.refusal(.conflict) { _ = try await service.edit(request, input: nil) }
        #expect(committed.withLock { !$0.isEmpty })
        #expect(try DocVerificationPreparationTests.truth(store) == committed.withLock { $0 })
      } else {
        let result = try await service.edit(request) { "New body" }
        #expect(result.ref == "doc:rules@2")
      }
      #expect(git.isExhausted)
    }
  }

  @Test func missingSuppliedInputPrecedesGit() async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      await Self.refusal(.usage) {
        _ = try await Self.service(home, store).edit(Self.request(), input: nil)
      }
    }
  }

  @Test func pendingOnlyCannotKeepBodyAndProtectedRecoveryIsAgentOwned() async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try AcmeDocAttachments.attach("pending", to: "service", in: store, state: "proposed")
      var request = DocEditRequest(slug: "pending")
      request.keepBody = true
      let before = try DocVerificationPreparationTests.truth(store)
      await Self.refusal(.usage) {
        _ = try await Self.service(home, store).edit(request, input: nil)
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      for scope in ["acme", Self.credential] {
        var service = try Self.service(home, store, approved: nil)
        service.workspace = scope
        do {
          _ = try service.authorizeEdit(DocEditRequest(slug: Self.credential))
          Issue.record("Ungated identity write")
        } catch let error as any CodedError {
          #expect(error.code == .humanOnly && error.nextBy == .agent)
          #expect(error.next == [scope == "acme" ? "silta --ws 'acme' doc ls" : "silta ws ls"])
        }
      }
    }
  }

}

extension DocWritePolicyTests {
  static func write(
    _ proposal: Bool, service: DocWriteService, request: DocEditRequest, body: String,
    why: String = "Share."
  ) async throws -> (ref: String, warnings: [OutputWarning]) {
    if proposal {
      let result = try DocProposalService(
        environment: service.environment, workspace: service.workspace
      ).propose(
        DocProposalRequest(
          slug: request.slug, title: request.title, about: request.about, why: why),
        input: { body })
      return (result.ref, result.warnings)
    }
    let result = try await service.edit(request, input: { body })
    return (result.ref, result.warnings)
  }

  @Test(
    arguments: [false, true].flatMap { proposal in [false, true].map { (proposal, $0) } },
    ["body", "metadata", "pending"])
  func newSecretTextRespectsCaller(caller: (Bool, Bool), field: String) async throws {
    let (proposal, human) = caller
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try Self.service(home, store, human: human)
      let metadata = field != "body"
      let slug = field == "pending" ? "pending" : "rules"
      if field == "pending" {
        try AcmeDocAttachments.attach(slug, to: "service", in: store, state: "proposed")
        try store.write {
          try $0.database.execute(sql: "UPDATE doc SET title=?", arguments: [Self.secret])
        }
      }
      var request = Self.request(slug)
      request.title = metadata ? Self.secret : "Rules"
      let body = metadata ? "Safe" : Self.secret
      let why = metadata ? Self.secret : "Share."
      if human {
        await Self.refusal(.invalid) {
          _ = try await Self.write(
            proposal, service: service, request: request, body: body, why: why)
        }
      } else {
        let result = try await Self.write(
          proposal, service: service, request: request, body: body, why: why)
        #expect(result.warnings.contains(SecretGuard.warning))
        let row = try DocProposalServiceTests.row(store, revision: field == "pending" ? 2 : 1)
        #expect(row["title"] as String == (metadata ? "[REDACTED:password]" : "Rules"))
        if !proposal {
          #expect(
            try store.read { try String.fetchOne($0, sql: "SELECT title FROM doc") }
              == row["title"] as String)
        }
        #expect(row["body_md"] as String == (metadata ? "Safe" : "[REDACTED:password]"))
        if proposal {
          #expect(row["message"] as String == (metadata ? "[REDACTED:password]" : "Share."))
        }
      }
    }
  }

  @Test(arguments: [false, true])
  func identitiesRefuseWithoutRewriteAndTypedReferencesWork(proposal: Bool) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try Self.service(home, store)
      let before = try DocVerificationPreparationTests.truth(store)
      await Self.refusal(.invalid) {
        _ = try await Self.write(
          proposal, service: service, request: Self.request(Self.credential), body: "Safe")
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      _ = try await Self.write(
        proposal, service: service, request: Self.request(String(repeating: "a", count: 52)),
        body: "Safe")
      try store.write {
        try $0.database.execute(sql: "UPDATE service SET slug=?", arguments: [Self.secret])
      }
      var encoded = Self.request()
      encoded.about = ["service:Password%3Dprivate123"]
      await Self.refusal(.invalid) {
        _ = try await Self.write(proposal, service: service, request: encoded, body: "Safe")
      }
    }
  }

  @Test(arguments: [false, true], [false, true])
  func ownedLegacyMetadataAndContentRemainLiteral(proposal: Bool, explicit: Bool) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try Self.service(home, store)
      try Self.seed(store, body: Self.secret)
      let title = "Legacy\n" + String(repeating: "é", count: 140) + Self.secret
      try store.write {
        try $0.database.execute(
          sql:
            "UPDATE doc SET title=?,kind='legacy label';"
            + " UPDATE doc_rev SET title=?,kind='legacy label'",
          arguments: [title, title])
      }
      var request = DocEditRequest(slug: "rules", title: explicit ? title : nil)
      if proposal { request.about = ["service:push", "topic:messaging"] }
      let result = try await Self.write(
        proposal, service: service, request: request, body: Self.secret)
      #expect(result.ref == "doc:rules@2" && result.warnings.isEmpty)
      let row = try DocProposalServiceTests.row(store, revision: 2)
      #expect((row["title"] as String).utf8.elementsEqual(title.utf8))
      #expect(row["kind"] as String == "legacy label" && row["body_md"] as String == Self.secret)
      request.title = title + " changed"
      await Self.refusal(.invalid) {
        _ = try await Self.write(proposal, service: service, request: request, body: "Safe")
      }
      request.title = "Valid"
      request.about = ["service:Password%3Dprivate123"]
      await Self.refusal(.invalid) {
        _ = try await Self.write(proposal, service: service, request: request, body: "Safe")
      }
    }
  }

  @Test(arguments: [false, true], ["raw", "masked"])
  func titleLimitsApplyBeforeAndAfterMasking(proposal: Bool, boundary: String) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try Self.service(home, store)
      let title =
        boundary == "raw"
        ? "Pwd=" + String(repeating: "x", count: 121)
        : "Pwd=x " + String(repeating: ".", count: 114)
      var request = Self.request()
      request.title = title
      #expect((title.count > 120) == (boundary == "raw"))
      #expect((SecretGuard.redacted(title).count > 120) == (boundary == "masked"))
      let before = try DocVerificationPreparationTests.truth(store)
      await Self.refusal(.invalid) {
        _ = try await Self.write(proposal, service: service, request: request, body: "Safe")
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test(arguments: [false, true], ["limit", "oversize", "redaction", "shrink"])
  func suppliedBodyBoundsPreserveStore(proposal: Bool, boundary: String) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try Self.service(home, store)
      let body: String
      switch boundary {
      case "redaction": body = "Pwd=x " + String(repeating: ".", count: 65_530)
      case "shrink": body = "Pwd=" + String(repeating: "x", count: 65_533)
      default: body = String(repeating: ".", count: boundary == "limit" ? 65_536 : 65_537)
      }
      let before = try DocVerificationPreparationTests.truth(store)
      if boundary == "limit" {
        if proposal {
          try AcmeDocAttachments.attach("rules", to: "service", in: store, state: "proposed")
          try store.write {
            try $0.database.execute(
              sql:
                "DELETE FROM link; INSERT INTO seq_counter(scope,next) VALUES('doc_rev:1:rules',20)"
            )
          }
        }
        let result = try await Self.write(
          proposal, service: service, request: Self.request(), body: body)
        #expect(result.ref == (proposal ? "doc:rules@20" : "doc:rules@1"))
        let row = try DocProposalServiceTests.row(store, revision: proposal ? 20 : 1)
        #expect((row["body_md"] as String).utf8.count == 65_536)
        if proposal {
          #expect(row["base_rev"] as Int? == nil && row["kind"] as String == "runbook")
        }
      } else {
        await Self.refusal(.invalid) {
          _ = try await Self.write(
            proposal, service: service, request: Self.request(), body: body)
        }
        #expect(try DocVerificationPreparationTests.truth(store) == before)
      }
    }
  }

  @Test(
    arguments: [false, true].flatMap { proposal in [false, true].map { (proposal, $0) } },
    [false, true])
  func suppliedNulRefusesBeforeGitOrMutation(caller: (Bool, Bool), unchanged: Bool) async throws {
    let (proposal, human) = caller
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let body = "Acme\u{0}private-tail"
      if unchanged { try Self.seed(store, body: body) }
      let before = try DocVerificationPreparationTests.truth(store)
      let git = ScriptedGitRunner(script: [
        (
          DocVerificationPreparationTests.request("origin/api", repo: repo),
          DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
        )
      ])
      let service = try Self.service(home, store, human: human, git: git)
      var request = Self.request()
      request.about = ["app:api"]
      request.allowSecret = true
      var failure: (any CodedError)?
      do {
        _ = try await Self.write(proposal, service: service, request: request, body: body)
      } catch let error as any CodedError { failure = error }
      #expect(failure?.code == .invalid && failure?.message == DocInputTests.refusal)
      #expect(git.requests.isEmpty)
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }
}
