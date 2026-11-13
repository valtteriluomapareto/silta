import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocArchivePolicyTests {
  @Test func gatePrecedesStorageAndMissingRefUsesReadRecovery() throws {
    try withScratchDirectory { home in
      let absent = DatabaseStore(
        home: home, clock: FakeClock(now: DocStoreTests.instant), jitter: { 0 })
      do {
        _ = try DocWritePolicyTests.service(home, absent, approved: nil).archive("rules")
        Issue.record("Archive bypassed the human gate")
      } catch let error as any CodedError { #expect(error.code == .humanOnly) }
      #expect(!FileManager.default.fileExists(atPath: home.appending(path: "silta.db").path))
      let store = try AcmeDocAttachments.make(in: home)
      do {
        _ = try DocWritePolicyTests.service(home, store).archive("missing")
        Issue.record("Missing document was archived")
      } catch let error as any CodedError {
        #expect(error.code == .notFound && error.nextBy == .agent)
        #expect(error.next == ["silta --ws 'acme' doc ls"])
      }
    }
  }

  @Test(arguments: [false, true])
  func archiveKeepsHistoryAndNoopLeavesTruthUnaudited(human: Bool) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try DocWritePolicyTests.seed(store, body: DocWritePolicyTests.secret)
      let git = ScriptedGitRunner(script: [])
      let service = try DocWritePolicyTests.service(home, store, human: human, git: git)
      let history = try store.read {
        try Row.fetchAll($0, sql: "SELECT * FROM doc_rev").map(\.description)
      }
      let first = try service.archive("doc:rules")
      #expect(first.archived && first.changed && first.ref == "doc:rules")
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM link WHERE rel='about'") }
          == 0)
      #expect(
        try store.read { try Row.fetchAll($0, sql: "SELECT * FROM doc_rev").map(\.description) }
          == history)
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") }
          == (human ? 0 : 1))
      let before = try DocVerificationPreparationTests.truth(store)
      let second = try service.archive("rules")
      #expect(second.archived && !second.changed && !second.approvalUsed)
      #expect(second.warnings.contains { $0.code == "approval_unused" })
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      #expect(git.requests.isEmpty)
    }
  }

  @Test(arguments: ["approval", "approval-change"])
  func lateApprovalFailureRollsBackArchiveAndLinks(failure: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try DocWritePolicyTests.seed(store)
      let target = failure == "approval" ? "ON approval" : "ON change_log WHEN NEW.kind='approval'"
      try store.write {
        try $0.database.execute(
          sql:
            "CREATE TRIGGER reject_archive BEFORE INSERT \(target) BEGIN SELECT RAISE(ABORT,'reject'); END"
        )
      }
      let before = try DocVerificationPreparationTests.truth(store)
      do {
        _ = try DocWritePolicyTests.service(home, store).archive("rules")
        Issue.record("Late approval failure committed an archive")
      } catch { #expect((error as? StorageError) == .constraintViolation) }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test func archivedResidualLinksAreARealCleanup() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try DocWritePolicyTests.seed(store)
      try store.write { try $0.database.execute(sql: "UPDATE doc SET archived=1") }
      let result = try DocWritePolicyTests.service(home, store).archive("rules")
      #expect(result.changed && result.approvalUsed)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM link WHERE rel='about'") }
          == 0)
    }
  }
}
