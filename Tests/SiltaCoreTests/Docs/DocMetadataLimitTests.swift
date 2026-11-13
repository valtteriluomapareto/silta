import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

struct DocMetadataLimitTests {
  @Test(arguments: [
    String(repeating: "é", count: 121), "Rules\rmore", "Rules\nmore", "Rules\u{2028}more",
    "Rules\u{2029}more",
  ])
  func titlesMustBeOneLineAndAtMost120Characters(title: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      var draft = DocVerificationPreparationTests.draft(["service:push"])
      draft.title = title
      let before = try DocStoreTests.snapshot(store)
      #expect(throws: DocError.self) {
        _ = try DocStoreTests.accept(draft, in: store, ids: SeededIDGenerator(seed: 71))
      }
      #expect(try DocStoreTests.snapshot(store) == before)
    }
  }

  @Test func exact120AndFixedKindSurviveAttachmentChanges() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let ids = SeededIDGenerator(seed: 71)
      var draft = DocVerificationPreparationTests.draft(["edge:api/service:push/sdk"])
      draft.title = String(repeating: "e\u{301}", count: 120)
      #expect(try DocStoreTests.accept(draft, in: store, ids: ids).kind == "contract")
      draft.about = ["service:push"]
      #expect(try DocStoreTests.accept(draft, in: store, ids: ids).kind == "contract")
      draft.kind = "runbook"
      #expect(try DocStoreTests.accept(draft, in: store, ids: ids).kind == "runbook")
    }
  }
}
