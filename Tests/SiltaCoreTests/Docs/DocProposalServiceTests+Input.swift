import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension DocProposalServiceTests {
  @Test(arguments: ["workspace", "about", "source", "storage"])
  func postInputFailuresKeepScopedDiscoveryAndStorageIdentity(kind: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      var service = try Self.service(home, store)
      var request = Self.request()
      if kind == "workspace" { service.workspace = "missing" }
      if kind == "about" { request.about = ["service:missing"] }
      if kind == "source" { request.task = "AC-99" }
      let before = try DocVerificationPreparationTests.truth(store)
      let error = try #require(
        Self.refusal(kind == "storage" ? .env : .notFound) {
          _ = try service.propose(request) {
            if kind == "storage" { throw StorageError.accessDenied }
            return "Private input"
          }
        })
      if kind == "storage" {
        #expect(error as? StorageError == .accessDenied)
        #expect(error.next == ["silta doctor"])
      } else {
        let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
        let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
        Golden.forTests().check(
          text.stderr + json.stdout, "doc-proposal-discovery-" + kind + ".txt")
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test(arguments: ["counter", "insert"])
  func boundsAndLateFailuresWriteNothing(failure: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try store.write {
        if failure == "counter" {
          try $0.database.execute(
            sql: "INSERT INTO seq_counter(scope,next) VALUES('doc_rev:1:rules',?)",
            arguments: [Int64.max])
        } else {
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
      #expect(
        throws: failure == "counter" ? StorageError.resourceExhausted : .constraintViolation
      ) {
        _ = try Self.service(home, store).propose(
          Self.request(), input: { String(repeating: ".", count: 65_536) })
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
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
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(id,uid,slug,name,task_prefix)
            VALUES(2,'beta','beta','Beta','BE')
            """)
      }
      try Self.task(store, seq: 1, workspace: 2)
      let before = try DocVerificationPreparationTests.truth(store)
      request.task = "BE-1"
      _ = Self.refusal(.invalid) {
        _ = try service.propose(request) {
          return "Body"
        }
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
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
            return "Body"
          }
        })
      #expect(error.next == [scope == "acme" ? "silta --ws 'acme' doc ls" : "silta ws ls"])
      #expect(!error.message.contains(DocWritePolicyTests.credential))
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

}
