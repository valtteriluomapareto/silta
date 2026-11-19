import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceEditorTests {
  @Test(arguments: ["workspace: [\n", "workspace: {slug: beta, name: Beta, task_prefix: BE}\n"])
  func unchangedInvalidInputEndsTheEditorLoop(invalidInput: String) throws {
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      var count = 0
      var failure: (any CodedError)?
      do {
        _ = try WorkspaceEditor.edit(
          slug: "acme", store: store, actor: TaskServiceTests.human(),
          identity: (SeededIDGenerator(seed: 2), WorkspaceConfigTests.instant)
        ) { file in
          count += 1
          if count == 1 {
            try invalidInput.write(to: file, atomically: true, encoding: .utf8)
          }
          guard count < 3 else { throw WorkspaceError.editor }
          return 0
        }
      } catch let error as any CodedError {
        failure = error
      }
      #expect(count == 2)
      #expect(failure?.code == .invalid)
      #expect(failure?.next == ["silta --ws 'acme' ws show"])
    }
  }

  @Test(arguments: [false, true])
  func savesRefuseConcurrentChangesAndRetainEditorInput(initiallyExists: Bool) throws {
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      let base = WorkspaceConfigTests.minimal
      if initiallyExists { try WorkspaceConfigTests.apply(base, to: store) }
      let proposed = base.replacingOccurrences(of: "name: Acme", with: "name: Edited")
      var buffer: URL?
      var failure: (any CodedError)?
      do {
        _ = try WorkspaceEditor.edit(
          slug: initiallyExists ? "acme" : nil, store: store, actor: TaskServiceTests.agent,
          identity: (SeededIDGenerator(seed: 2), WorkspaceConfigTests.instant),
          approved: "yes, update the Acme fixture"
        ) { file in
          guard buffer == nil else { throw WorkspaceError.editor }
          buffer = file
          try proposed.write(to: file, atomically: true, encoding: .utf8)
          try WorkspaceConfigTests.apply(base + "services: [mailer]\n", to: store)
          return 0
        }
      } catch let error as any CodedError {
        failure = error
      }
      let file = try #require(buffer)
      defer {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())  // fixture buffer
      }
      let retained = try String(contentsOf: file, encoding: .utf8)
      let service = try store.read { try String.fetchOne($0, sql: "SELECT slug FROM service") }
      let approvals = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") }
      #expect(failure?.code == .conflict)
      #expect(failure?.nextBy == .agent)
      #expect(failure?.next == (initiallyExists ? ["silta --ws 'acme' ws show"] : ["silta ws ls"]))
      #expect(failure?.message.contains(file.path) == true)
      #expect(retained == proposed)
      #expect(service == "mailer")
      #expect(approvals == 0)
    }
  }
  @Test func fileInputCapturesConfigurationBeforeReading() throws {
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      let original = WorkspaceConfigTests.minimal
      try WorkspaceConfigTests.apply(original, to: store)
      func read() throws -> String {
        try WorkspaceConfigTests.apply(original + "services: [mailer]\n", to: store)
        return original.replacingOccurrences(of: "name: Acme", with: "name: Edited")
      }
      #expect(throws: WorkspaceEditConflict.self) {
        try WorkspaceEditor.apply(
          try read(), slug: "acme", store: store, actor: TaskServiceTests.agent,
          identity: (SeededIDGenerator(seed: 2), WorkspaceConfigTests.instant),
          approved: "yes, update the Acme fixture")
      }
      let service = try store.read { try String.fetchOne($0, sql: "SELECT slug FROM service") }
      #expect(service == "mailer")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }

}
