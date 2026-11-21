#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct DocTriageTests {
    @Test func tickedVisibleRevisionsAreTriagedAsOneBatch() async throws {
      let writes = ControlledWrites()
      try await fixtureModel(writes) { model in
        let refs = model.documentRefs.sorted()
        #expect(refs == ["doc:order-contract@3", "doc:push-categories@1"])
        #expect(model.triageSelectedDocuments(accept: true, among: refs) == nil)
        model.actions.selectedDocuments = Set(refs + ["doc:gone@9"])
        let accept = model.triageSelectedDocuments(accept: true, among: [refs[1]])
        let sent = await writes.next()
        #expect(sent.write == .triageDocuments(accept: [refs[1]], reject: []))
        sent.continuation.resume(returning: nil)
        await accept?.value
        #expect(model.actions.selectedDocuments == Set(refs))
        let reject = model.triageSelectedDocuments(accept: false, among: refs)
        let second = await writes.next()
        #expect(second.write == .triageDocuments(accept: [], reject: refs))
        second.continuation.resume(returning: nil)
        await reject?.value
      }
    }

    @Test func theDocsViewTriagesTheOpenRevision() async throws {
      let writes = ControlledWrites()
      try await fixtureModel(writes) { model in
        let running = model.triageDocuments(accept: ["doc:order-contract@3"], reject: [])
        let sent = await writes.next()
        #expect(sent.write == .triageDocuments(accept: ["doc:order-contract@3"], reject: []))
        let target = try #require(model.target(AppModel.documentsTarget))
        #expect(model.actions.isSending(target))
        sent.continuation.resume(returning: nil)
        await running?.value
      }
    }

    @Test func acceptingFromDocsUpdatesTheOpenRevision() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
      let writer = AppWriter(reader: reader)
      let model = AppModel(
        reader: reader, now: { AppV2Fixture.now },
        writer: { write, workspace in try await writer.send(write, workspace: workspace) },
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
      await model.refresh().value
      model.openDocument("doc:push-categories@1")
      await model.loadDocuments(force: true)
      #expect(model.documents.document?.state == "proposed")
      model.actions.selectedDocuments = ["doc:push-categories@1"]
      await model.triageDocuments(accept: ["doc:push-categories@1"], reject: [])?.value
      #expect(model.documents.document?.state == "accepted")
      #expect(model.actions.selectedDocuments.isEmpty)
      await model.selectWorkspace("acme").value
      model.actions.selectedDocuments = ["doc:order-contract@3"]
      await model.selectWorkspace("other").value
      #expect(model.actions.selectedDocuments.isEmpty)
    }

    private func fixtureModel(
      _ writes: ControlledWrites, _ body: (AppModel) async throws -> Void
    ) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
      let model = AppModel(
        reader: reader, now: { AppV2Fixture.now },
        writer: { write, workspace in try await writes.write(write, workspace) },
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
      await model.refresh().value
      try await body(model)
    }
  }
#endif
