#if DEBUG
  import Darwin
  import Foundation
  import Observation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor @Suite(.timeLimit(.minutes(1)))
  struct ControlActionTests {
    @Test func wireAcceptsJSONFormattingAndRejectsEscapedDuplicateKeys() throws {
      let formatted = Data(
        #"{ "version" : 1, "seq" : 1, "run" : "current", "action" : "copy\u002eref" }"#.utf8)
      #expect(try ControlRequest(data: formatted, run: "current", sequence: 1).action == .copyRef)
      let duplicate = Data(
        #"{"version":1,"seq":1,"run":"current","action":"refresh","act\u0069on":"copy.ref"}"#.utf8)
      #expect(throws: ControlRefusal.invalidRequest) {
        try ControlRequest(data: duplicate, run: "current", sequence: 1)
      }
    }

    @Test func statusStaysBusyUntilProductWriteCompletes() async throws {
      let writes = ControlledWrites()
      let refreshing = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let finish = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      defer {
        refreshing.continuation.finish()
        finish.continuation.finish()
      }
      let model = AppModel(
        writer: { write, workspace in try await writes.write(write, workspace) },
        load: { _, _, force in
          if force {
            refreshing.continuation.yield(())
            var permits = finish.stream.makeAsyncIterator()
            _ = await permits.next()
          }
          return AppLoadedData(
            workspaces: [], workspace: "acme", snapshot: nil, map: nil,
            version: 1, checkedAt: AppV2Fixture.now)
        })
      await model.refresh().value
      let write = try #require(model.perform(.acceptAnswer(ref: "AC-14/2"), for: "AC-14/2"))
      let pending = await writes.next()
      #expect(!ControlState.readiness(model).idle)
      pending.continuation.resume()
      var updates = refreshing.stream.makeAsyncIterator()
      _ = await updates.next()
      #expect(!ControlState.readiness(model).idle)
      finish.continuation.yield(())
      await write.value
      #expect(ControlState.readiness(model).idle)
    }

    @Test func strictWireDistinguishesMalformedAndStaleRequests() throws {
      let fields: [String: Any] = ["action": "select", "ref": "AC-12", "screen": "board"]
      #expect(try wire(fields).action == .select("board:AC-12"))
      #expect(throws: ControlRefusal.staleRun) { try wire(fields, run: "previous") }
      #expect(throws: ControlRefusal.invalidRequest) { try wire(fields, seq: true) }
      #expect(throws: ControlRefusal.invalidRequest) { try wire(fields, seq: 1.5) }
      #expect(throws: ControlRefusal.invalidRequest) { try wire(fields, seq: NSNull()) }
      #expect(throws: ControlRefusal.invalidRequest) { try wire(fields, seq: 2) }
      #expect(throws: ControlRefusal.invalidRequest) {
        try wire(fields.merging(["unused": "value"]) { _, later in later })
      }
      #expect(throws: ControlRefusal.invalidRequest) {
        try wire(["action": "select", "screen": "docs", "ref": "doc:operation@1", "view": 1])
      }
    }

    @Test func copyReturnsExactTextInThePrivateRunResponse() async throws {
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
      model.inspect(task: "AC-9")
      await model.loadTaskDetail()
      let actions = ControlActions(model: model)
      #expect(model.boardInspectorPresented && model.taskDetail.value?.ref == "AC-9")
      let copied = await actions.perform(.copyRef)
      #expect(copied.response(run: "owned", sequence: 1)["copied"] as? String == "AC-9")
      let command = await actions.perform(.copyCommand)
      let text = try #require(command.response(run: "owned", sequence: 2)["copied"] as? String)
      let canonical = try #require(realpath(fixture.home.path, nil))
      defer { free(canonical) }
      let path = String(cString: canonical)
      #expect(text == "SILTA_HOME='\(path)' silta --ws 'acme' task show 'AC-9' --timeline")
      #expect(await actions.perform(.select("board:AC-9")) == .noop)
      #expect(await actions.perform(.toggleInspector) == .accepted)
      #expect(await actions.perform(.copyCommand) == .refused(.unavailable))
      #expect(await actions.perform(.select("board:AC-9999")) == .refused(.unknownSelection))
      #expect(model.route == .board)
      #expect(
        await actions.perform(.select("docs:doc:missing@1:changes")) == .refused(.unknownSelection))
      #expect(model.route == .board)
      #expect(await actions.perform(.navigate(.mywork)) == .accepted)
      #expect(await actions.perform(.navigate(.mywork)) == .noop)
      #expect(await actions.perform(.toggleInspector) == .refused(.unavailable))
      #expect(await actions.perform(.refresh) == .accepted)
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
      let selected = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      withObservationTracking {
        _ = model.documentSelection
      } onChange: {
        selected.continuation.yield(())
      }
      let result = Task { await actions.perform(.select("docs:doc:order-contract@3:document")) }
      var selections = selected.stream.makeAsyncIterator()
      _ = await selections.next()
      #expect(!ControlState.readiness(model).idle)
      let view = Task { await model.loadDocuments() }
      var iterator = entered.stream.makeAsyncIterator()
      _ = await iterator.next()
      model.navigate(to: .mywork)
      #expect(await result.value == .refused(.superseded))
      #expect(model.route == .mywork)
      unblock.continuation.yield(())
      await view.value
      selected.continuation.finish()
      entered.continuation.finish()
      unblock.continuation.finish()
    }

    @Test func failedRefreshSettlesWithRefusal() async {
      let model = AppModel(load: { _, _, _ in throw AppLoadFailure(message: "Fixture read failed") }
      )
      let actions = ControlActions(model: model)
      #expect(await actions.perform(.refresh) == .refused(.readFailed))
    }

    @Test func cancelledRetryDoesNotValidateAValueFromBeforeTheFailure() async throws {
      let fixture = try FixtureLaunch.prepare()
      defer {
        try? FileManager.default.removeItem(  // cleanup
          at: fixture.home.deletingLastPathComponent())
      }
      let reader = try AppReader(home: fixture.home, user: fixture.user, now: { fixture.now })
      let old = try reader.task("AC-9", workspace: "acme")
      let detail = TaskDetailModel()
      await detail.load(workspace: "acme", ref: "AC-9", version: 2) { old }
      await detail.load(workspace: "acme", ref: "AC-9", version: 3) {
        throw AppLoadFailure(message: "Failed to load the current task")
      }
      #expect(detail.phase(workspace: "acme", ref: "AC-9", version: 3) == .failed)
      let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let hold = AsyncStream<Void>.makeStream()
      defer {
        entered.continuation.finish()
        hold.continuation.finish()
      }
      let retry = Task {
        await detail.load(workspace: "acme", ref: "AC-9", version: 3) {
          entered.continuation.yield(())
          var iterator = hold.stream.makeAsyncIterator()
          _ = await iterator.next()
          return old
        }
      }
      var reads = entered.stream.makeAsyncIterator()
      _ = await reads.next()
      retry.cancel()
      await retry.value
      #expect(detail.value?.ref == old.ref)
      #expect(detail.phase(workspace: "acme", ref: "AC-9", version: 3) == .loading)
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
