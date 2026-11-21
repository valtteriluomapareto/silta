#if DEBUG
  import Foundation
  import Observation
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

    /// A model on a fresh fixture home that reads and writes through the real facade.
    private func fixtureModel(_ body: (AppModel, AppReader) async throws -> Void) async throws {
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
      try await body(model, reader)
    }

    @Test func aCommentRefreshesTheOpenDetailBeforeReleasingTheTarget() async throws {
      try await fixtureModel { model, _ in
        let ref = "AC-15"
        let body = "Acme inspector discussion."
        model.inspect(task: ref)
        await model.loadTaskDetail()
        let old = try #require(model.taskDetail.value)
        #expect(!old.comments.contains { $0.body == body })

        let target = try #require(model.target(ref))
        model.actions.setDraft(body, for: target)
        let send = try #require(model.comment(task: ref))
        #expect(model.actions.isSending(target))
        #expect(model.comment(task: ref) == nil)
        let refreshedOnRelease = Mutex<Bool?>(nil)
        withObservationTracking {
          _ = model.actions.isSending(target)
        } onChange: {
          let refreshed = MainActor.assumeIsolated {
            !model.taskDetail.isLoading
              && model.taskDetail.value?.comments.contains { $0.body == body } == true
          }
          refreshedOnRelease.withLock { $0 = refreshed }
        }
        await send.value
        #expect(refreshedOnRelease.withLock { $0 } == true)
        #expect(!model.actions.isSending(target))
        #expect(model.taskDetail.value?.comments.last?.body == body)
      }
    }

    @Test func acceptingTheSelectionTriagesItAndPrunesWhatLeft() async throws {
      try await fixtureModel { model, _ in
        let all = ["AC-21", "AC-22", "AC-23"]
        #expect(model.proposalRefs == Set(all))
        #expect(model.acceptSelectedProposals(among: all) == nil)
        model.actions.selectedProposals = ["AC-21", "AC-23", "AC-99"]
        await model.acceptSelectedProposals(among: all)?.value
        #expect(model.proposalRefs == ["AC-22"])
        #expect(model.actions.selectedProposals.isEmpty)
        let target = try #require(model.target(AppModel.proposalsTarget))
        #expect(model.actions.failures[target] == nil)
      }
    }

    @Test func aStaleSelectionFailsWholeAndKeepsWhatIsStillProposed() async throws {
      try await fixtureModel { model, reader in
        model.actions.selectedProposals = ["AC-21", "AC-23"]
        try AppWriter(reader: reader).perform(
          .acceptProposals(refs: ["AC-21"]), workspace: "acme")
        await model.acceptSelectedProposals(among: ["AC-21", "AC-22", "AC-23"])?.value
        let target = try #require(model.target(AppModel.proposalsTarget))
        #expect(model.actions.failures[target]?.code == "conflict")
        #expect(model.proposalRefs == ["AC-22", "AC-23"])
        #expect(model.actions.selectedProposals == ["AC-23"])
      }
    }

    @Test func droppingSendsTheVisibleTickedProposalsWithAnOptionalReason() async throws {
      try await fixtureModel { model, reader in
        let all = ["AC-21", "AC-22", "AC-23"]
        #expect(model.dropSelectedProposals(among: all, why: "x") == nil)
        model.actions.selectedProposals = ["AC-21", "AC-23"]
        await model.dropSelectedProposals(among: ["AC-21"], why: "  Not now.  ")?.value
        #expect(try reader.task("AC-21", workspace: "acme").status == "dropped")
        #expect(try reader.task("AC-21", workspace: "acme").result == "Not now.")
        #expect(try reader.task("AC-23", workspace: "acme").status == "proposed")
        #expect(model.actions.selectedProposals == ["AC-23"])
        await model.dropSelectedProposals(among: all, why: "   ")?.value
        #expect(try reader.task("AC-23", workspace: "acme").result == "Dropped in triage.")
        #expect(model.proposalRefs == ["AC-22"])
      }
    }

    @Test func aSearchNeverSendsAHiddenTickedProposal() async throws {
      try await fixtureModel { model, _ in
        model.actions.selectedProposals = ["AC-21", "AC-23"]
        await model.acceptSelectedProposals(among: ["AC-21"])?.value
        #expect(model.proposalRefs == ["AC-22", "AC-23"])
        #expect(model.actions.selectedProposals == ["AC-23"])
      }
    }

    @Test func unblockingTheReadyTaskClearsItsItem() async throws {
      try await fixtureModel { model, _ in
        let ready = model.visibleData?.snapshot?.work.items.filter { $0.kind == "ready" }
        #expect(ready?.map(\.refs) == [["AC-17"]])
        let comment = try #require(model.target("AC-17"))
        model.actions.setDraft("Check the banner copy.", for: comment)
        await model.unblock("AC-17")?.value
        #expect(model.actions.draft(comment) == "Check the banner copy.")
        #expect(model.visibleData?.snapshot?.work.items.contains { $0.kind == "ready" } == false)
        #expect(
          model.visibleData?.snapshot?.board.todo.first { $0.ref == "AC-17" }?.status == "todo")
      }
    }

    @Test func workspaceSwitchesClearTheProposalSelection() async {
      let model = AppModel(load: { _, workspace, _ in
        AppLoadedData(
          workspaces: [], workspace: workspace ?? "acme", snapshot: nil, map: nil, version: 1,
          checkedAt: AppV2Fixture.now)
      })
      await model.refresh().value
      model.actions.selectedProposals = ["AC-21"]
      await model.selectWorkspace("beta").value
      #expect(model.actions.selectedProposals.isEmpty)
    }

    @Test func coreRefusalsShowTheirCodeAndShareOneDraftAcrossScreens() async throws {
      try await fixtureModel { model, reader in
        let snapshot = try #require(model.visibleData?.snapshot)
        let question = MyWorkContent(snapshot: snapshot, search: "", now: AppV2Fixture.now)
          .questions.first?.item.ref
        let inspector = BoardContent(
          snapshot: snapshot, apps: [], filter: BoardFilter(), search: ""
        )
        .newestQuestion(for: "AC-12", reader: reader, workspace: "acme")?.question
        #expect(question == "AC-12/1" && inspector == question)
        let fromMyWork = try #require(question.flatMap { model.target($0) })
        model.actions.setDraft("Other.", for: fromMyWork)
        #expect(inspector.flatMap { model.target($0) }.map { model.actions.draft($0) } == "Other.")
        let refused = try #require(model.perform(.acceptAnswer(ref: "AC-12/1"), for: "AC-12/1"))
        await refused.value
        let failure = try #require(model.target("AC-12/1").flatMap { model.actions.failures[$0] })
        #expect(failure.code == "invalid" && !failure.message.isEmpty)
      }
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

    @Test func aReplyPostsIntoItsThreadWithItsOwnDraft() async throws {
      let writes = ControlledWrites()
      let loads = Loads()
      let model = await makeModel(writes, loads)
      let reply = try #require(model.target(AppModel.replyTarget("AC-9/1")))
      let comment = try #require(model.target("AC-9"))
      model.actions.setDraft("Thanks, merging.", for: reply)
      model.actions.setDraft("New thread draft", for: comment)
      let first = try #require(model.reply(to: "AC-9/1", task: "AC-9"))
      let request = await writes.next()
      #expect(
        request.write == .comment(task: "AC-9", body: "Thanks, merging.", replyTo: "AC-9/1"))
      request.continuation.resume(throwing: Refused())
      await first.value
      #expect(model.actions.draft(reply) == "Thanks, merging.")
      #expect(model.actions.failures[reply] != nil)
      let second = try #require(model.reply(to: "AC-9/1", task: "AC-9"))
      (await writes.next()).continuation.resume()
      await second.value
      #expect(model.actions.draft(reply) == "")
      #expect(model.actions.draft(comment) == "New thread draft")
      #expect(loads.forced.withLock { $0 } == 2)
    }

    @Test func noWriterMeansNoAction() async {
      let model = AppModel(load: { _, _, _ in nil })
      #expect(model.perform(.acceptAnswer(ref: "AC-14/2"), for: "AC-14/2") == nil)
    }
  }
#endif
