#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct ControlActionTests {
    @Test func strictWireDistinguishesMalformedAndStaleRequests() throws {
      let fields: [String: Any] = ["action": "select", "ref": "AC-12", "screen": "board"]
      #expect(try wire(fields).action == .select("board:AC-12"))
      #expect(throws: ControlRefusal.staleRun) { try wire(fields, run: "previous") }
      #expect(throws: ControlRefusal.invalidRequest) { try wire(fields, seq: true) }
      #expect(throws: ControlRefusal.invalidRequest) { try wire(fields, seq: 2) }
      #expect(throws: ControlRefusal.invalidRequest) {
        try wire(fields.merging(["unused": "value"]) { _, later in later })
      }
      #expect(throws: ControlRefusal.invalidRequest) {
        try wire(["action": "select", "screen": "docs", "ref": "doc:operation@1", "view": 1])
      }
    }

    @Test func actionsDriveTheFixtureThroughExistingHandlersAndCopySources() async throws {
      let fixture = try FixtureLaunch.prepare()
      defer {
        try? FileManager.default.removeItem(at: fixture.home.deletingLastPathComponent())  // cleanup
      }
      let reader = try AppReader(home: fixture.home, user: fixture.user, now: { fixture.now })
      let session = AppReadSession(reader: reader, now: { fixture.now })
      let model = AppModel(
        reader: reader,
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
      await model.refresh().value
      var copies: [String] = []
      let actions = ControlActions(
        model: model,
        copy: {
          copies.append($0)
          return true
        })
      #expect(await actions.perform(.select("board:AC-9")) == .accepted)
      #expect(model.boardInspectorPresented && model.taskDetail.value?.ref == "AC-9")
      #expect(await actions.perform(.copyRef) == .accepted)
      #expect(await actions.perform(.copyCommand) == .accepted)
      #expect(copies.first == "AC-9" && copies.last?.contains("task show 'AC-9'") == true)
      #expect(await actions.perform(.toggleInspector) == .accepted)
      #expect(await actions.perform(.copyCommand) == .refused(.unavailable))
      #expect(await actions.perform(.select("workspace:app:acme-backend")) == .accepted)
      #expect(model.workspaceNode == "app:acme-backend")
      #expect(await actions.perform(.select("docs:doc:order-contract@3:changes")) == .accepted)
      #expect(model.documents.document?.ref == "doc:order-contract@3")
      #expect(await actions.perform(.select("board:AC-9999")) == .refused(.unknownSelection))
      #expect(await actions.perform(.navigate(.mywork)) == .accepted)
      #expect(await actions.perform(.navigate(.mywork)) == .noop)
      #expect(await actions.perform(.toggleInspector) == .refused(.unavailable))
      #expect(await actions.perform(.refresh) == .accepted)
    }

    private func wire(_ fields: [String: Any], run: String = "current", seq: Any = 1) throws
      -> ControlRequest
    {
      let envelope = fields.merging(["version": 1, "run": run, "seq": seq]) { _, later in later }
      let data = try JSONSerialization.data(
        withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
      return try ControlRequest(data: data, run: "current", sequence: 1)
    }
  }
#endif
