import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposalSelectionTests {
  @Test(arguments: ["current", "prepared", "none", "failure"])
  func selectionIsResolvedAfterInputAndPreparedOutcomesStayAuthoritative(kind: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      var environment = try DocProposalServiceTests.service(home, store).environment
      if kind == "prepared" { environment.workspaceSelection = .success("acme") }
      if kind == "none" { environment.workspaceSelection = .success(nil) }
      if kind == "failure" { environment.workspaceSelection = .failure(StorageError.accessDenied) }
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO meta(key,value) VALUES('current_workspace','missing')
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """)
      }
      let service = DocProposalService(environment: environment, workspace: nil, approved: nil)
      var read = false
      var committed: [[String]] = []
      var failure: (any CodedError)?
      var result: DocProposalResult?
      do {
        result = try service.propose(DocProposalServiceTests.request()) {
          read = true
          try store.write {
            try $0.database.execute(
              sql: "UPDATE meta SET value=? WHERE key='current_workspace'",
              arguments: [kind == "prepared" ? "missing" : "acme"])
          }
          committed = try DocVerificationPreparationTests.truth(store)
          return "Body"
        }
      } catch let error as any CodedError { failure = error }
      #expect(read)
      if kind == "current" || kind == "prepared" {
        #expect(failure == nil && result?.workspace == "acme" && result?.ref == "doc:rules@1")
      } else {
        #expect(result == nil)
        #expect(failure?.code == (kind == "none" ? .notFound : .env))
        #expect(try DocVerificationPreparationTests.truth(store) == committed)
      }
    }
  }
}
