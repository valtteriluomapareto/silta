#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct ReviewActionTests {
    @Test func markDoneNeedsAResultAndSendsTheDrafts() async throws {
      let writes = ControlledWrites()
      try await fixtureModel(writes) { model in
        let result = try #require(model.target(AppModel.doneResultTarget("AC-9")))
        let sha = try #require(model.target(AppModel.doneSHATarget("AC-9")))
        model.actions.setDraft("   ", for: result)
        #expect(model.markDone("AC-9") == nil)
        model.actions.setDraft("Retries cap at five minutes.\nFriction: none", for: result)
        model.actions.setDraft(" 7d03b1f ", for: sha)
        let first = model.markDone("AC-9")
        let sent = await writes.next()
        #expect(
          sent.write
            == .markDone(
              ref: "AC-9", result: "Retries cap at five minutes.\nFriction: none", sha: "7d03b1f"))
        sent.continuation.resume(throwing: AppLoadFailure(message: "gate", commands: []))
        await first?.value
        #expect(model.actions.draft(result).hasPrefix("Retries cap"))
        #expect(model.actions.draft(sha) == " 7d03b1f ")
        model.actions.setDraft("", for: sha)
        let second = model.markDone("AC-9")
        let again = await writes.next()
        #expect(
          again.write
            == .markDone(
              ref: "AC-9", result: "Retries cap at five minutes.\nFriction: none", sha: nil))
        again.continuation.resume(returning: nil)
        await second?.value
        #expect(model.actions.draft(result) == "")
      }
    }

    @Test func requestChangesAsksTheSubmitter() async throws {
      let writes = ControlledWrites()
      try await fixtureModel(writes) { model in
        let review = try #require(model.visibleData?.snapshot?.work.reviews.first)
        let submitter = try #require(review.submission?.actor)
        let changes = try #require(model.target(AppModel.changesTarget("AC-9")))
        model.actions.setDraft("Also cap the queue size.", for: changes)
        let running = model.requestChanges("AC-9", from: submitter)
        let sent = await writes.next()
        #expect(
          sent.write
            == .comment(
              task: "AC-9", body: "Also cap the queue size.", kind: "question", to: [submitter]))
        sent.continuation.resume(returning: nil)
        await running?.value
        #expect(model.actions.draft(changes) == "")
      }
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
