import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocStoredIdentityTests {
  static let kinds = [
    "workspace", "doc", "doc_rev", "service", "topic", "edge", "app", "repo",
    "service-endpoint", "app-endpoint",
  ]

  @Test(arguments: Self.kinds, [false, true])
  func editRefusesUnsupportedStoredIdentity(kind: String, nulSuffix: Bool) async throws {
    let uid = nulSuffix ? "K\u{0}tail" : "K"
    try await withScratchDirectory { home in
      let (store, request) = try Self.fixture(home, kind: kind)
      let table = Self.table(kind)
      try Self.replaceUID(uid, table: table, store: store)
      let before = try DocVerificationPreparationTests.truth(store)
      let git = ScriptedGitRunner(script: [])
      do {
        let error = await Self.failure {
          _ = try await DocWritePolicyTests.service(home, store, git: git)
            .edit(request, input: nil)
        }
        Self.expectBackup(error)
        #expect(try DocVerificationPreparationTests.truth(store) == before)
        #expect(try Self.uidBytes(table, store: store) == Data(uid.utf8))
        #expect(git.requests.isEmpty)
      }
    }
  }

  @Test(arguments: [
    "workspace", "service", "topic", "edge", "app", "repo", "service-endpoint", "app-endpoint",
  ])
  func bindingRefusesBeforeDecodingIdentity(kind: String) throws {
    try withScratchDirectory { home in
      let (store, request) = try Self.fixture(home, kind: kind)
      let table = Self.table(kind)
      try Self.replaceUID("K\u{0}tail", table: table, store: store)
      let before = try DocVerificationPreparationTests.truth(store)
      var draft = DocDraft(slug: request.slug, body: "Original")
      draft.title = request.title
      draft.about = request.about
      do {
        var failure: (any CodedError)?
        do {
          _ = try DocVerification.readBinding(draft, workspace: 1, store: store)
        } catch let error as any CodedError { failure = error }
        Self.expectBackup(failure)
        #expect(try DocVerificationPreparationTests.truth(store) == before)
      }
    }
  }

  @Test(arguments: Self.kinds)
  func nulSuffixRaceKeepsTheCommittedIdentity(kind: String) async throws {
    try await withScratchDirectory { home in
      let (store, initial) = try Self.fixture(home, kind: kind)
      let table = Self.table(kind)
      let original = try #require(try Self.uidBytes(table, store: store))
      let changed = original + Data("\u{0}changed".utf8)
      let changedText = try #require(String(data: changed, encoding: .utf8))
      var request = initial
      request.keepBody = false
      var committed: [[String]] = []
      do {
        let error = await Self.failure {
          _ = try await DocWritePolicyTests.service(home, store).edit(request) {
            try Self.replaceUID(
              changedText, table: table, store: store)
            committed = try DocVerificationPreparationTests.truth(store)
            return "Replacement"
          }
        }
        Self.expectBackup(error)
        #expect(!committed.isEmpty)
        #expect(try DocVerificationPreparationTests.truth(store) == committed)
        #expect(try Self.uidBytes(table, store: store) == changed)
      }
    }
  }

  @Test func canonicalEquivalentBodyRaceRefuses() async throws {
    let changed = Data("cafe\u{301}".utf8)
    #expect(String(data: changed, encoding: .utf8) == "café")
    #expect(changed != Data("café".utf8))
    try await Self.bodyRace(initial: "café", changed: changed)
  }

  @Test func cappedAndEmptyBaselineBodiesStayDistinct() async throws {
    try await Self.bodyRace(
      initial: String(repeating: "x", count: DocInput.maximumBytes + 1), changed: Data())
  }

  static func bodyRace(initial: String, changed: Data) async throws {
    try await withScratchDirectory { home in
      let (store, initialRequest) = try Self.fixture(home, kind: "doc")
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT)", arguments: [Data(initial.utf8)])
      }
      let captured = try store.read {
        try DocEditBaseline.read("rules", workspace: 1, keepBody: false, in: $0)
      }
      #expect(captured.body == (initial.utf8.count > DocInput.maximumBytes ? nil : initial))
      var request = initialRequest
      request.keepBody = false
      var committed: [[String]] = []
      let error = await Self.failure {
        _ = try await DocWritePolicyTests.service(home, store).edit(request) {
          try store.write {
            try $0.database.execute(
              sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT)", arguments: [changed])
          }
          committed = try DocVerificationPreparationTests.truth(store)
          return "Replacement"
        }
      }
      #expect(error?.code == .conflict)
      #expect(try DocVerificationPreparationTests.truth(store) == committed)
      #expect(
        try store.read { try Data.fetchOne($0, sql: "SELECT CAST(body_md AS BLOB) FROM doc_rev") }
          == changed)
    }
  }

  @Test func proposalKeepsBackupRecoveryForUnsupportedBaseline() async throws {
    try await withScratchDirectory { home in
      let (store, _) = try Self.fixture(home, kind: "workspace")
      try Self.replaceUID("owned\u{0}suffix", table: "workspace", store: store)
      #expect(try Self.uidBytes("workspace", store: store)?.contains(0) == true)
      let before = try DocVerificationPreparationTests.truth(store)
      let git = ScriptedGitRunner(script: [])
      let environment = try DocVerificationPreparationTests.environment(
        home, store: store, git: git)
      let error = await Self.failure {
        _ = try DocProposalService(environment: environment, workspace: "acme", approved: nil)
          .propose(DocProposalRequest(slug: "rules", why: "Record the Acme rule")) { "Original" }
      }
      Self.expectBackup(error)
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      #expect(git.requests.isEmpty)
    }
  }

  static func fixture(_ home: URL, kind: String) throws
    -> (DatabaseStore, DocEditRequest)
  {
    let store = try AcmeDocAttachments.make(in: home)
    try DocWritePolicyTests.seed(store)
    var request = DocWritePolicyTests.request()
    request.keepBody = true
    switch kind {
    case "topic": request.about = ["topic:messaging"]
    case "app", "repo": request.about = ["app:api"]
    case "edge", "service-endpoint", "app-endpoint":
      request.about = ["edge:api/service:push/sdk"]
    default: break
    }
    return (store, request)
  }

  static func table(_ kind: String) -> String {
    kind == "service-endpoint" ? "service" : kind == "app-endpoint" ? "app" : kind
  }

  static func replaceUID(_ uid: String, table: String, store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql: "UPDATE \(table) SET uid=CAST(? AS TEXT)", arguments: [Data(uid.utf8)])
    }
  }

  static func uidBytes(_ table: String, store: DatabaseStore) throws -> Data? {
    try store.read { try Data.fetchOne($0, sql: "SELECT CAST(uid AS BLOB) FROM \(table)") }
  }

  static func expectBackup(_ error: (any CodedError)?) {
    #expect(error?.code == .env)
    #expect(error?.next == ["silta backup"])
    #expect(error?.nextBy == .human)
    #expect(error?.message.contains("Stored IDs must be nonempty ASCII text without NUL.") == true)
  }

  static func failure(_ operation: () async throws -> Void) async -> (any CodedError)? {
    do { try await operation() } catch let error as any CodedError { return error } catch {
      Issue.record("Expected a coded identity refusal: \(error)")
    }
    return nil
  }
}
