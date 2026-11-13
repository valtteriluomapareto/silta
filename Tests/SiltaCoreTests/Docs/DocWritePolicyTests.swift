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

  @Test(arguments: [false, true])
  func textSecretsRefuseHumanAndRedactApprovedAgent(human: Bool) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try Self.service(home, store, human: human)
      if human {
        await Self.refusal(.invalid) { _ = try await service.edit(Self.request()) { Self.secret } }
      } else {
        let result = try await service.edit(Self.request()) { Self.secret }
        #expect(result.ref == "doc:rules@1" && result.warnings.contains(SecretGuard.warning))
        #expect(
          try store.read { try String.fetchOne($0, sql: "SELECT body_md FROM doc_rev") }
            == "[REDACTED:password]")
      }
    }
  }

  @Test func identitiesRefuseWithoutRewriteAndTyped52ExemptionSurvives() async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try Self.service(home, store)
      let before = try DocVerificationPreparationTests.truth(store)
      await Self.refusal(.invalid) {
        _ = try await service.edit(Self.request(Self.credential)) { "Safe" }
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      var allowed = Self.request(Self.credential)
      allowed.allowSecret = true
      _ = try await service.edit(allowed) { "Safe" }
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT slug FROM doc") }
          == Self.credential)
      _ = try await service.edit(Self.request(String(repeating: "a", count: 52))) { "Safe" }
      try store.write {
        try $0.database.execute(
          sql: "UPDATE service SET slug=?", arguments: [Self.secret])
      }
      var encoded = Self.request("encoded")
      encoded.about = ["service:Password%3Dprivate123"]
      await Self.refusal(.invalid) { _ = try await service.edit(encoded) { "Safe" } }
    }
  }

  @Test func keptOwnedBodyIsLiteralIncludingArchivedOversizeAndSecret() async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let body = Self.secret + String(repeating: "é", count: 40_000)
      try Self.seed(store, body: body)
      try store.write { try $0.database.execute(sql: "UPDATE doc SET archived=1") }
      var request = DocEditRequest(slug: "rules")
      request.keepBody = true
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
                sql:
                  "UPDATE doc_rev SET uid='new-baseline' WHERE doc_id=(SELECT id FROM doc WHERE slug='rules')"
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

  @Test(arguments: [65_536, 65_537])
  func suppliedBodyBoundAndMissingInputPrecedeGit(bytes: Int) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try Self.service(home, store)
      if bytes == 65_536 {
        _ = try await service.edit(Self.request()) { String(repeating: ".", count: bytes) }
      } else {
        await Self.refusal(.invalid) {
          _ = try await service.edit(Self.request()) { String(repeating: ".", count: bytes) }
        }
      }
      await Self.refusal(.usage) { _ = try await service.edit(Self.request(), input: nil) }
    }
  }

  @Test func postRedactionExpansionIsBoundedBeforeStore() async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let text = "Pwd=x " + String(repeating: ".", count: 65_530)
      #expect(text.utf8.count == 65_536 && SecretGuard.redacted(text).utf8.count > 65_536)
      let before = try DocVerificationPreparationTests.truth(store)
      await Self.refusal(.invalid) {
        _ = try await Self.service(home, store).edit(Self.request()) { text }
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }
}
