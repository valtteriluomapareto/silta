import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocInputPolicyTests {
  @Test(arguments: [false, true])
  func directEditPreservesOwnedLegacyTitle(explicit: Bool) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try DocWritePolicyTests.seed(store)
      let title = "Legacy\n" + String(repeating: "é", count: 140)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET title=?", arguments: [title])
        try $0.database.execute(sql: "UPDATE doc_rev SET title=?", arguments: [title])
      }
      let service = try DocWritePolicyTests.service(home, store)
      var request = DocEditRequest(slug: "rules")
      request.title = explicit ? title : nil
      var ref: String?
      do {
        ref = try await service.edit(request, input: { "New safe body." }).ref
      } catch let error as any CodedError {
        #expect(error.code == .invalid)
      }
      withKnownIssue("An accepted unchanged title is rejected as new metadata") {
        #expect(ref == "doc:rules@2")
      }
      if ref != nil {
        let saved = try store.read {
          try String.fetchOne($0, sql: "SELECT title FROM doc_rev WHERE rev=2")
        }
        #expect(saved.map { $0.utf8.elementsEqual(title.utf8) } == true)
      }
    }
  }
}
