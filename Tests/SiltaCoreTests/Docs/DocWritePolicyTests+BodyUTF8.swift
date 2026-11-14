import Foundation
import GRDB
import SiltaTestSupport
import Synchronization
import Testing

@testable import SiltaCore

extension DocWritePolicyTests {
  @Test func keepBodyChangeOnlyAfterNULRefusesWithoutMutation() async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      var initial = DocVerificationPreparationTests.draft(["app:api"])
      initial.slug = "rules"
      _ = try DocStoreTests.accept(initial, in: store, ids: SeededIDGenerator(seed: 82))
      let original = Data("Acme\u{0}one".utf8)
      let changed = Data("Acme\u{0}two".utf8)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT)", arguments: [original])
      }
      #expect(
        try store.read { try Data.fetchOne($0, sql: "SELECT CAST(body_md AS BLOB) FROM doc_rev") }
          == original)
      let committed = Mutex<[[String]]>([])
      let git = ScriptedGitRunner(
        script: [
          (
            DocVerificationPreparationTests.request("origin/api", repo: repo),
            DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
          )
        ],
        beforeRequest: { _ in
          try store.write {
            try $0.database.execute(
              sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT)", arguments: [changed])
          }
          let truth = try DocVerificationPreparationTests.truth(store)
          committed.withLock { $0 = truth }
        })
      var request = DocEditRequest(slug: "rules")
      request.keepBody = true
      var refused = false
      do {
        _ = try await Self.service(home, store, git: git).edit(request, input: nil)
      } catch let error as any CodedError {
        #expect(error.code == .conflict)
        refused = error.code == .conflict
      }
      #expect(git.isExhausted && committed.withLock { !$0.isEmpty })
      #expect(
        try store.read {
          try Data.fetchOne($0, sql: "SELECT CAST(body_md AS BLOB) FROM doc_rev WHERE rev=1")
        } == changed)
      let after = try DocVerificationPreparationTests.truth(store)
      withKnownIssue("Kept-body baseline must compare bytes after NUL before allocating or writing")
      {
        #expect(refused)
        #expect(after == committed.withLock { $0 })
      }
    }
  }

  @Test func keepBodyInvalidStoredUTF8RefusesWithoutMutation() async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try Self.seed(store)
      let invalid = Data([0x41, 0xFF, 0x42])
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT)", arguments: [invalid])
      }
      #expect(
        try store.read { try Data.fetchOne($0, sql: "SELECT CAST(body_md AS BLOB) FROM doc_rev") }
          == invalid)
      let before = try DocVerificationPreparationTests.truth(store)
      var request = DocEditRequest(slug: "rules")
      request.keepBody = true
      var failure: StorageError?
      do {
        _ = try await Self.service(home, store).edit(request, input: nil)
      } catch let error as StorageError {
        #expect(error == .corrupt)
        failure = error
      }
      let after = try DocVerificationPreparationTests.truth(store)
      withKnownIssue(
        "Invalid retained baseline UTF-8 must refuse instead of saving replacement characters"
      ) {
        #expect(failure == .corrupt)
        #expect(after == before)
      }
      #expect(
        try store.read {
          try Data.fetchOne($0, sql: "SELECT CAST(body_md AS BLOB) FROM doc_rev WHERE rev=1")
        } == invalid)
    }
  }
}
