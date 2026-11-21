#if DEBUG
  import Foundation
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  /// The New Task sheet's write: a human's task goes straight to todo, never started.
  @Suite(.blockingTestWork)
  struct AppWriterCreateTests {
    @Test func aNewTaskLandsInTodoWithEveryField() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        var new = AppNewTask(title: "Show delivery time on the order page")
        new.description = "Customers keep asking when an order arrives."
        new.acceptance = "- The order page shows the estimated delivery day."
        new.app = "acme-web"
        new.parent = "AC-15"
        new.priority = 1
        let ref = try #require(
          try AppWriter(reader: reader).perform(.createTask(new), workspace: "acme"))
        let task = try reader.task(ref, workspace: "acme")
        #expect(task.status == "todo" && task.createdBy == "human:acme")
        #expect(task.title == new.title && task.description == new.description)
        #expect(task.acceptance == new.acceptance)
        #expect(task.app == "acme-web" && task.parent == "AC-15" && task.priority == 1)
        #expect(task.claimedBy == nil && task.worktree == nil)
        let log = try String(
          contentsOf: scratch.appending(path: "silta-home/log/2026-11-16.jsonl"), encoding: .utf8)
        #expect(log.contains("\"command\":\"app add\"") && !log.contains("delivery"))
      }
    }

    @Test func aSecretInTheAcceptanceIsRefusedAndNothingIsCreated() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        let before = try reader.snapshot(workspace: "acme").board.todo.count
        var new = AppNewTask(title: "Rotate the key")
        new.acceptance = "Uses ghp_" + String(repeating: "a1B2", count: 9)
        let refused = try AppWriterTests.failure {
          try AppWriter(reader: reader).perform(.createTask(new), workspace: "acme")
        }
        #expect(refused.code == .invalid)
        #expect(try reader.snapshot(workspace: "acme").board.todo.count == before)
      }
    }

    @Test func anUnknownAppIsRefused() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        var new = AppNewTask(title: "Somewhere else")
        new.app = "acme-desktop"
        let refused = try AppWriterTests.failure {
          try AppWriter(reader: reader).perform(.createTask(new), workspace: "acme")
        }
        #expect(refused.code != nil)
      }
    }
  }
#endif
