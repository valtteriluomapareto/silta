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
        try? FileManager.default.removeItem(  // cleanup
          at: fixture.home.deletingLastPathComponent())
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
      #expect(await actions.perform(.select("board:AC-9999")) == .refused(.unknownSelection))
      #expect(model.route == .board)
      #expect(model.boardInspectorPresented && model.taskDetail.value?.ref == "AC-9")
      #expect(await actions.perform(.copyRef) == .accepted)
      #expect(await actions.perform(.copyCommand) == .accepted)
      let failingCopy = ControlActions(model: model, copy: { _ in false })
      #expect(await failingCopy.perform(.copyRef) == .refused(.copyFailed))
      #expect(copies.first == "AC-9" && copies.last?.contains("task show 'AC-9'") == true)
      #expect(await actions.perform(.toggleInspector) == .accepted)
      #expect(await actions.perform(.copyCommand) == .refused(.unavailable))
      #expect(await actions.perform(.select("workspace:app:acme-backend")) == .accepted)
      #expect(model.workspaceNode == "app:acme-backend")
      #expect(await actions.perform(.select("docs:doc:order-contract@3:changes")) == .accepted)
      #expect(model.documents.document?.ref == "doc:order-contract@3")
      #expect(
        await actions.perform(.select("docs:doc:missing@1:changes")) == .refused(.unknownSelection))
      #expect(model.route == .docs && model.documents.document?.ref == "doc:order-contract@3")
      #expect(await actions.perform(.navigate(.mywork)) == .accepted)
      #expect(await actions.perform(.navigate(.mywork)) == .noop)
      #expect(await actions.perform(.toggleInspector) == .refused(.unavailable))
      #expect(await actions.perform(.refresh) == .accepted)
    }

    @Test func mailboxRefusesMalformedCurrentRequestThenDrainsFutureAndIgnoresStale() async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: directory) }  // cleanup
      let model = AppModel(load: { _, _, _ in nil })
      var publications: [String] = []
      let mailbox = try ControlMailbox(
        directory: directory, run: "owned", actions: ControlActions(model: model),
        publish: { publications.append("\($0)/\($1)") },
        fail: { error in
          Issue.record("Unexpected mailbox failure: \(error)")
        })
      let future = try JSONSerialization.data(
        withJSONObject: [
          "version": 1, "run": "owned", "seq": 2, "action": "nav", "screen": "mywork",
        ],
        options: [.sortedKeys, .withoutEscapingSlashes])
      try future.write(to: directory.appending(path: "req-2.json"), options: .atomic)
      await mailbox.check()
      #expect(mailbox.sequence == 0)
      let malformed = Data(
        #"{"action":"refresh","action":"copy.ref","run":"owned","seq":1,"version":1}"#.utf8)
      try malformed.write(to: directory.appending(path: "req-1.json"), options: .atomic)
      await mailbox.check()
      #expect(mailbox.sequence == 2)
      #expect(publications == ["1/0", "1/1", "2/1", "2/2"])
      let first = try result(directory, 1)
      let second = try result(directory, 2)
      #expect(first["reason"] as? String == "invalidRequest")
      #expect(second["outcome"] as? String == "noop")
      try future.write(to: directory.appending(path: "req-1.json"), options: .atomic)
      await mailbox.check()
      #expect(publications.count == 4)
    }

    @Test func selectionReportsSupersessionWhenUserChangesRouteDuringARead() async throws {
      let fixture = try FixtureLaunch.prepare()
      defer {
        try? FileManager.default.removeItem(  // cleanup
          at: fixture.home.deletingLastPathComponent())
      }
      let reader = try AppReader(home: fixture.home, user: fixture.user, now: { fixture.now })
      let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let unblock = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let page = try reader.documents(workspace: "acme")
      let docs = DocsModel(readList: { _, _, _, _, _ in
        entered.continuation.yield(())
        var iterator = unblock.stream.makeAsyncIterator()
        _ = await iterator.next()
        return page
      })
      let model = AppModel(
        reader: reader, documents: docs,
        load: { _, _, _ in
          AppLoadedData(
            workspaces: [], workspace: "acme", snapshot: nil, map: nil,
            version: 1, checkedAt: AppV2Fixture.now)
        })
      await model.refresh().value
      let actions = ControlActions(model: model)
      let result = Task { await actions.perform(.select("docs:doc:order-contract@3:document")) }
      var iterator = entered.stream.makeAsyncIterator()
      _ = await iterator.next()
      model.navigate(to: .mywork)
      unblock.continuation.yield(())
      #expect(await result.value == .refused(.superseded))
      #expect(model.route == .mywork)
      entered.continuation.finish()
      unblock.continuation.finish()
    }

    @Test func failedRefreshSettlesWithRefusal() async {
      let model = AppModel(load: { _, _, _ in throw AppLoadFailure(message: "Fixture read failed") }
      )
      let actions = ControlActions(model: model)
      #expect(await actions.perform(.refresh) == .refused(.readFailed))
    }

    private func result(_ directory: URL, _ sequence: Int) throws -> [String: Any] {
      let data = try Data(contentsOf: directory.appending(path: "res-\(sequence).json"))
      return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
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
