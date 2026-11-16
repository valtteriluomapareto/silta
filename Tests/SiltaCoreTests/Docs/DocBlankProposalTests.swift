import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocBlankProposalTests {
  @Test(arguments: ["", " \t\n"], [false, true])
  func blankBodyRefusesBeforeDatabaseEffects(body: String, existing: Bool) throws {
    withKnownIssue("Document guidance and recovery preserve the requested contract.") {
      try withScratchDirectory { home in
        let store = existing ? try AcmeDocAttachments.make(in: home) : ExportFixture.store(home)
        let before = existing ? try DocVerificationPreparationTests.truth(store) : []
        var failure: (any CodedError)?
        do {
          _ = try DocProposalServiceTests.service(home, store).propose(
            DocProposalServiceTests.request(), input: { body })
        } catch let error as any CodedError { failure = error }
        #expect(failure?.code == .invalid)
        if existing {
          #expect(try DocVerificationPreparationTests.truth(store) == before)
        } else {
          #expect(!FileManager.default.fileExists(atPath: store.path))
        }
      }
    }
  }
}
