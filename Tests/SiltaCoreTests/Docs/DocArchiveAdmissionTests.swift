import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocArchiveAdmissionTests {
  @Test(arguments: [false, true])
  func neverAcceptedArchiveRefusesWithoutConsumingApproval(human: Bool) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      _ = try DocProposalServiceTests.service(home, store).propose(
        DocProposalServiceTests.request(), input: { "Pending knowledge" })
      let before = try DocVerificationPreparationTests.truth(store)
      var failure: (any CodedError)?
      do {
        _ = try DocWritePolicyTests.service(home, store, human: human).archive("rules")
      } catch let error as any CodedError { failure = error }
      #expect(failure?.code == .invalid)
      #expect(failure?.next == ["silta --ws 'acme' doc ls --archived --offset 0 --limit 20"])
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test func archivedPendingIsExplicitInBothReadSurfaces() throws {
    try withScratchDirectory { home in
      let store = try DocProposalInboxTests().fixture(home, pending: 3)
      _ = try DocWritePolicyTests.service(home, store).archive("rules")
      let before = try DocVerificationPreparationTests.truth(store)
      try store.read { (db: Database) throws in
        let normal = try DocProposalInbox(workspace: "acme", at: AcmeDocAttachments.instant, in: db)
        let all = try DocProposalInbox(
          workspace: "acme", at: AcmeDocAttachments.instant, all: true, in: db)
        #expect(try normal.count() == 0 && normal.groups().isEmpty)
        #expect(try all.count() == 1 && all.groups().first?.total == 3)
      }
      let read = DocService(workspace: "acme", store: store)
      #expect(try read.list().entries.isEmpty)
      #expect(try read.list(archived: true).entries.count == 4)
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }
}
