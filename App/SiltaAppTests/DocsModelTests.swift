#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct DocsModelTests {
    @Test func groupsPreferAcceptedAndReaderAppendsAllBodyPages() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      await docs.refresh(reader, workspace: "acme", about: nil, archived: false)
      let order = try #require(docs.groups(search: "order").first)
      #expect(order.preferred?.ref == "doc:order-contract@2")
      #expect(docs.groups(search: "push").first?.preferred?.state == "proposed")
      docs.ref = "doc:operations@1"
      await docs.show(reader, workspace: "acme")
      #expect(docs.nextLine != nil)
      await docs.show(reader, workspace: "acme", append: true)
      #expect(docs.body.contains("Operational step 500.") && docs.nextLine == nil)
      docs.ref = "doc:order-contract@2"
      docs.view = .comments
      await docs.show(reader, workspace: "acme")
      #expect(docs.comments.count == 1 && docs.versions.count == 3 && docs.failure == nil)
      await docs.refresh(reader, workspace: "acme", about: "service:missing", archived: false)
      #expect(docs.entries.isEmpty && docs.listFailure != nil)
    }
  }
#endif
