#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Synchronization
  import Testing

  @MainActor @Suite(.timeLimit(.minutes(1)))
  struct ActionModelTests {
    struct Refused: Error {}

    final class Loads: Sendable {
      let forced = Mutex(0)
    }

    private func makeModel(_ writes: ControlledWrites, _ loads: Loads) async -> AppModel {
      let model = AppModel(
        writer: { write, workspace in try await writes.write(write, workspace) },
        load: { _, _, force in
          if force { loads.forced.withLock { $0 += 1 } }
          return AppLoadedData(
            workspaces: [], workspace: "acme", snapshot: nil, map: nil, version: 1,
            checkedAt: AppV2Fixture.now)
        })
      await model.refresh().value
      return model
    }

    @Test func aFailedAnswerKeepsItsDraftAndASuccessClearsIt() async throws {
      let writes = ControlledWrites()
      let loads = Loads()
      let model = await makeModel(writes, loads)
      let target = try #require(model.target("AC-12/1"))
      model.actions.setDraft("  Show them under Other. ", for: target)
      let first = try #require(model.answer(question: "AC-12/1", task: "AC-12"))
      let request = await writes.next()
      #expect(
        request.write == .answer(task: "AC-12", question: "AC-12/1", body: "Show them under Other.")
      )
      #expect(request.workspace == "acme")
      #expect(model.actions.isSending(target))
      request.continuation.resume(throwing: Refused())
      await first.value
      #expect(model.actions.draft(target) == "  Show them under Other. ")
      #expect(model.actions.failures[target]?.message == "Couldn’t save to Silta.")
      #expect(!model.actions.isSending(target))
      let second = try #require(model.answer(question: "AC-12/1", task: "AC-12"))
      #expect(model.actions.failures[target] == nil)
      (await writes.next()).continuation.resume()
      await second.value
      #expect(model.actions.draft(target) == "")
      #expect(model.actions.failures[target] == nil)
      #expect(loads.forced.withLock { $0 } == 2)
    }

    @Test func aTargetSendsOneWriteAtATimeAndEveryWriteRefreshes() async throws {
      let writes = ControlledWrites()
      let loads = Loads()
      let model = await makeModel(writes, loads)
      let target = try #require(model.target("AC-12/1"))
      model.actions.setDraft("Other.", for: target)
      let first = try #require(model.answer(question: "AC-12/1", task: "AC-12"))
      let request = await writes.next()
      #expect(model.answer(question: "AC-12/1", task: "AC-12") == nil)
      let accept = try #require(model.perform(.acceptAnswer(ref: "AC-14/2"), for: "AC-14/2"))
      let second = await writes.next()
      #expect(second.write == .acceptAnswer(ref: "AC-14/2"))
      request.continuation.resume()
      await first.value
      #expect(loads.forced.withLock { $0 } == 1)
      second.continuation.resume(throwing: Refused())
      await accept.value
      #expect(loads.forced.withLock { $0 } == 2)
    }

    @Test func coreRefusalsShowTheirCodeAndShareOneDraftAcrossScreens() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
      let writer = AppWriter(reader: reader)
      let model = AppModel(
        reader: reader, now: { AppV2Fixture.now },
        writer: { write, workspace in try writer.perform(write, workspace: workspace) },
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
      await model.refresh().value
      let snapshot = try #require(model.visibleData?.snapshot)
      let question = MyWorkContent(snapshot: snapshot, search: "", now: AppV2Fixture.now)
        .questions.first?.item.ref
      let inspector = BoardContent(snapshot: snapshot, app: nil, search: "", proposals: false)
        .newestQuestion(for: "AC-12", reader: reader, workspace: "acme")?.question
      #expect(question == "AC-12/1" && inspector == question)
      let refused = try #require(model.perform(.acceptAnswer(ref: "AC-12/1"), for: "AC-12/1"))
      await refused.value
      let failure = try #require(model.target("AC-12/1").flatMap { model.actions.failures[$0] })
      #expect(failure.code == "invalid" && !failure.message.isEmpty)
    }

    @Test func emptyDraftsDoNotSendAndCommentsTargetTheTask() async throws {
      let writes = ControlledWrites()
      let loads = Loads()
      let model = await makeModel(writes, loads)
      let task = try #require(model.target("AC-15"))
      model.actions.setDraft(" \n ", for: task)
      #expect(model.comment(task: "AC-15") == nil)
      #expect(model.answer(question: "AC-12/1", task: "AC-12") == nil)
      model.actions.setDraft("Start with the empty state.", for: task)
      let sent = try #require(model.comment(task: "AC-15"))
      let request = await writes.next()
      #expect(request.write == .comment(task: "AC-15", body: "Start with the empty state."))
      request.continuation.resume()
      await sent.value
      #expect(model.actions.draft(task) == "")
      #expect(loads.forced.withLock { $0 } == 1)
    }

    @Test func noWriterMeansNoAction() async {
      let model = AppModel(load: { _, _, _ in nil })
      #expect(model.perform(.acceptAnswer(ref: "AC-14/2"), for: "AC-14/2") == nil)
    }
  }
#endif
