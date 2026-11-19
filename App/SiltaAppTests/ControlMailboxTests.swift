#if DEBUG
  import Foundation
  import Observation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor @Suite(.timeLimit(.minutes(1)))
  struct ControlMailboxTests {
    @Test func mailboxWatcherDrainsFutureRequestAndRefusesStaleRunAtNextSequence() async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: directory) }  // cleanup
      let model = AppModel(load: { _, _, _ in nil })
      let publications = AsyncStream<String>.makeStream()
      defer { publications.continuation.finish() }
      let mailbox = try ControlMailbox(
        directory: directory, run: "owned", actions: ControlActions(model: model),
        publish: { publications.continuation.yield("\($0)/\($1)") },
        fail: { error in
          Issue.record("Unexpected mailbox failure: \(error)")
        })
      let future = try JSONSerialization.data(
        withJSONObject: [
          "version": 1, "run": "owned", "seq": 2, "action": "nav", "screen": "mywork",
        ],
        options: [.sortedKeys, .withoutEscapingSlashes])
      try post(future, sequence: 2, in: directory)
      #expect(mailbox.sequence == 0)
      let malformed = Data(
        #"{"action":"refresh","action":"copy.ref","run":"owned","seq":1,"version":1}"#.utf8)
      try post(malformed, sequence: 1, in: directory)
      var events = publications.stream.makeAsyncIterator()
      for expected in ["1/0", "1/1", "2/1", "2/2"] {
        #expect(await events.next() == expected)
      }
      #expect(mailbox.sequence == 2)
      let first = try result(directory, 1)
      let second = try result(directory, 2)
      #expect(first["reason"] as? String == "invalidRequest")
      #expect(second["outcome"] as? String == "noop")
      let stale = Data(#"{"version":1,"run":"old","seq":3,"action":"nav","screen":"board"}"#.utf8)
      try post(stale, sequence: 3, in: directory)
      #expect(await events.next() == "3/2")
      #expect(await events.next() == "3/3")
      #expect(try result(directory, 3)["reason"] as? String == "staleRun")
      #expect(model.route == .mywork)

      try post(Data(repeating: 0x20, count: 16_385), sequence: 4, in: directory)
      #expect(await events.next() == "4/3")
      #expect(await events.next() == "4/4")
      #expect(try result(directory, 4)["reason"] as? String == "invalidRequest")
      try FileManager.default.createSymbolicLink(
        at: directory.appending(path: "req-5.json"),
        withDestinationURL: directory.appending(path: "req-2.json"))
      #expect(await events.next() == "5/4")
      #expect(await events.next() == "5/5")
      #expect(try result(directory, 5)["reason"] as? String == "invalidRequest")
    }

    @Test func refreshObservesAnOutsideWriteAndWaitsForTheCurrentInspector() async throws {
      let fixture = try FixtureLaunch.prepare()
      let directory = fixture.home.deletingLastPathComponent()
      defer { try? FileManager.default.removeItem(at: directory) }  // cleanup
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
      let original = try #require(model.visibleData)
      let waiting = try #require(original.snapshot?.work.waitingCount)
      #expect(ControlState.readiness(model).idle)

      try AppTestCLI.run(
        ["--ws", "acme", "task", "add", "--quiet", "An outside Acme proposal"], home: fixture.home)
      let versionChange = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      defer { versionChange.continuation.finish() }
      withObservationTracking {
        _ = model.visibleData?.version
      } onChange: {
        versionChange.continuation.yield(())
      }
      let publications = AsyncStream<Int>.makeStream()
      defer { publications.continuation.finish() }
      let mailbox = try ControlMailbox(
        directory: directory, run: "owned", actions: ControlActions(model: model),
        publish: { _, settled in publications.continuation.yield(settled) },
        fail: { Issue.record("Mailbox failed: \($0)") })
      defer { withExtendedLifetime(mailbox) {} }
      let refresh = Data(#"{"version":1,"run":"owned","seq":1,"action":"refresh"}"#.utf8)
      try post(refresh, sequence: 1, in: directory)

      var versions = versionChange.stream.makeAsyncIterator()
      _ = await versions.next()
      var events = publications.stream.makeAsyncIterator()
      #expect(await events.next() == 0)
      let current = try #require(model.visibleData)
      #expect(current.version != original.version)
      #expect(current.snapshot?.work.waitingCount == waiting + 1)
      #expect(model.taskDetail.value?.ref == "AC-9")
      #expect(!ControlState.readiness(model).idle)
      #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "res-1.json").path))

      await checkHeldViewRead(model, reader, version: current.version, mailbox: mailbox)
      #expect(await events.next() == 1)
      #expect(try result(directory, 1)["outcome"] as? String == "accepted")
      #expect(await ControlActions(model: model).perform(.refresh) == .accepted)
      #expect(model.visibleData?.version == current.version)
    }

    private func checkHeldViewRead(
      _ model: AppModel, _ reader: AppReader, version: Int?, mailbox: ControlMailbox
    ) async {
      let reading = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let finish = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      defer {
        reading.continuation.finish()
        finish.continuation.finish()
      }
      let view = Task {
        await model.taskDetail.load(workspace: "acme", ref: "AC-9", version: version) {
          reading.continuation.yield(())
          var permits = finish.stream.makeAsyncIterator()
          _ = await permits.next()
          return try reader.task("AC-9", workspace: "acme")
        }
      }
      var reads = reading.stream.makeAsyncIterator()
      _ = await reads.next()
      #expect(mailbox.sequence == 0)
      #expect(!ControlState.readiness(model).idle)
      finish.continuation.yield(())
      await view.value
    }

    private func result(_ directory: URL, _ sequence: Int) throws -> [String: Any] {
      let data = try Data(contentsOf: directory.appending(path: "res-\(sequence).json"))
      return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func post(_ data: Data, sequence: Int, in directory: URL) throws {
      let temporary = directory.appending(path: ".request-\(sequence)")
      try data.write(to: temporary)
      try FileManager.default.linkItem(
        at: temporary, to: directory.appending(path: "req-\(sequence).json"))
    }
  }
#endif
