#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct SteeringCommentTests {
    @Test func questionRecipientsAreTheAgentsOnTheTaskNewestFirst() throws {
      try fixture { reader in
        let task = try reader.task("AC-14", workspace: "acme")
        #expect(
          TaskFacts.agents(task) == [
            TaskFacts.Recipient(actor: "agent:codex:fixture", label: "Codex · session fixture"),
            TaskFacts.Recipient(actor: "agent:codex:review", label: "Codex · session review"),
          ])
        let review = try reader.task("AC-9", workspace: "acme")
        #expect(TaskFacts.agents(review).map(\.actor).contains("agent:claude:review"))
        #expect(
          TaskFacts.agents(try reader.task("AC-15", workspace: "acme")).map(\.actor) == [
            "agent:codex:fixture"
          ])
      }
    }

    @Test func theComposerSendsTheChosenKindAndRecipient() async throws {
      let writes = ControlledWrites()
      try await fixtureModel(writes) { model in
        let target = try #require(model.target("AC-14"))
        model.actions.setDraft("Keep the queue on logout.", for: target)
        let decision = model.comment(task: "AC-14", kind: .decision)
        let first = await writes.next()
        #expect(
          first.write
            == .comment(task: "AC-14", body: "Keep the queue on logout.", kind: "decision"))
        first.continuation.resume(returning: nil)
        await decision?.value

        model.actions.setDraft("Does it clear when off?", for: target)
        #expect(model.comment(task: "AC-14", kind: .question, to: nil) == nil)
        let question = model.comment(task: "AC-14", kind: .question, to: "agent:codex:fixture")
        let second = await writes.next()
        #expect(
          second.write
            == .comment(
              task: "AC-14", body: "Does it clear when off?", kind: "question",
              to: ["agent:codex:fixture"]))
        second.continuation.resume(returning: nil)
        await question?.value
      }
    }

    @Test func resolveAndReopenUseTheirOwnTargets() async throws {
      let writes = ControlledWrites()
      try await fixtureModel(writes) { model in
        let resolve = model.resolve(thread: "AC-9/1")
        let sent = await writes.next()
        #expect(sent.write == .resolveThreads(refs: ["AC-9/1"]))
        let target = try #require(model.target(AppModel.resolveTarget("AC-9/1")))
        #expect(model.actions.isSending(target))
        sent.continuation.resume(returning: nil)
        await resolve?.value
        let reopen = model.reopen(thread: "AC-9/1")
        let again = await writes.next()
        #expect(again.write == .reopenThreads(refs: ["AC-9/1"]))
        again.continuation.resume()
        await reopen?.value
      }
    }

    private func fixture(_ body: (AppReader) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      try body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }))
    }

    private func fixtureModel(
      _ writes: ControlledWrites, _ body: (AppModel) async throws -> Void
    ) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
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
