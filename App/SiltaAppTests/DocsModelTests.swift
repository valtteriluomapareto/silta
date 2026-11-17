#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct DocsModelTests {
    @Test func failedReloadKeepsTheCurrentDocumentAndBody() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      docs.ref = "doc:operations@1"
      await docs.show(reader, workspace: "acme")
      let original = docs.document
      let body = docs.body
      #expect(original != nil && !body.isEmpty)
      let path = home.appending(path: "silta.db").path
      let files = FileManager.default
      let mode = try files.attributesOfItem(atPath: path)[.posixPermissions]
      defer {
        try? files.setAttributes(  // restore the owned fixture database
          [.posixPermissions: mode ?? 0o600], ofItemAtPath: path)
      }
      try files.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
      await docs.show(reader, workspace: "acme", force: true)
      #expect(docs.failure != nil && !docs.loading)
      #expect(docs.document == original && docs.body == body)
    }

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
