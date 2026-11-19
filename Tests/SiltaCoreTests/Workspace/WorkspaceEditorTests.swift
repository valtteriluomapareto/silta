import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceEditorTests {
  @Test func unchangedInvalidInputEndsTheEditorLoop() throws {
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      var count = 0
      var failure: WorkspaceError?
      do {
        _ = try WorkspaceEditor.edit(
          slug: "acme", store: store, actor: TaskServiceTests.human(),
          identity: (SeededIDGenerator(seed: 2), WorkspaceConfigTests.instant)
        ) { file in
          count += 1
          if count == 1 {
            try "workspace: [\n".write(to: file, atomically: true, encoding: .utf8)
          }
          guard count < 3 else { throw WorkspaceError.editor }
          return 0
        }
      } catch let error as WorkspaceError {
        failure = error
      }
      withKnownIssue("#256: an unchanged invalid editor buffer keeps reopening") {
        #expect(count == 2)
        #expect(failure?.code == .invalid)
      }
    }
  }

  @Test(arguments: [false, true])
  func savesRefuseAConcurrentChangesAndRetainEditorInput(initiallyExists: Bool) throws {
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      let base = WorkspaceConfigTests.minimal
      if initiallyExists { try WorkspaceConfigTests.apply(base, to: store) }
      let proposed = base.replacingOccurrences(of: "name: Acme", with: "name: Edited")
      var buffer: URL?
      var failure: WorkspaceError?
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
      } catch let error as WorkspaceError {
        failure = error
      }
      let file = try #require(buffer)
      defer {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())  // fixture buffer
      }
      let retained = try? String(contentsOf: file, encoding: .utf8)  // missing before a conflict fix
      let service = try store.read { try String.fetchOne($0, sql: "SELECT slug FROM service") }
      let approvals = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") }
      withKnownIssue("#256: the save can erase the competing writer's configuration") {
        #expect(failure?.code == .conflict)
        #expect(retained == proposed)
        #expect(service == "mailer")
        #expect(approvals == 0)
      }
    }
  }
}
