#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct NewTaskTests {
    @Test func theSheetCreatesATodoTaskAndRemembersItsRef() async throws {
      try await fixtureModel { model, reader in
        var new = AppNewTask(title: "  Show delivery time  ")
        new.acceptance = " - Shows the day. "
        new.app = "acme-web"
        #expect(NewTaskForm.canCreate(new))
        #expect(!NewTaskForm.canCreate(AppNewTask(title: "   ")))
        await model.createTask(NewTaskForm.trimmed(new), copyPrompt: false)?.value
        let ref = try #require(model.createdTask)
        #expect(model.createdPrompt == nil)
        let task = try reader.task(ref, workspace: "acme")
        #expect(task.title == "Show delivery time" && task.acceptance == "- Shows the day.")
        #expect(task.status == "todo")
        #expect(model.visibleData?.snapshot?.board.todo.contains { $0.ref == ref } == true)
      }
    }

    @Test func aRefusedTaskKeepsTheSheetsFailureAndCreatesNothing() async throws {
      try await fixtureModel { model, _ in
        var new = AppNewTask(title: "Elsewhere")
        new.app = "acme-desktop"
        await model.createTask(new, copyPrompt: true)?.value
        #expect(model.createdTask == nil && model.createdPrompt == nil)
        let target = try #require(model.target(AppModel.newTaskTarget))
        #expect(model.actions.failures[target] != nil)
      }
    }

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
  }
#endif
