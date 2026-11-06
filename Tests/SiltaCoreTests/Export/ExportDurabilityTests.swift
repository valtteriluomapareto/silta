import Darwin
import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

struct ExportDurabilityTests {
  @Test func filesAndDirectoriesAreSyncedBeforeSwap() throws {
    try withScratchDirectory { scratch in
      let prepared = try ExportPublishTests.changeAndPrepare(scratch)
      let synced = Mutex<Set<String>>([])
      let moves = ExportMoves(
        swap: { from, to in
          let paths = synced.withLock { $0 }
          let expected = try? ExportServiceTests.tree(URL(filePath: from))  // asserted below
          #expect(expected?.isEmpty == false)
          for path in expected?.keys ?? [String: Data]().keys {
            #expect(paths.contains(from + "/" + path), "unsynced \(path)")
          }
          #expect(paths.contains(from))
          #expect(paths.contains(from + "/tasks"))
          return renamex_np(from, to, UInt32(RENAME_SWAP))
        },
        sync: { url in
          try ExportDurability.sync(url)
          _ = synced.withLock { $0.insert(url.path) }
        })
      _ = try ExportPublishTests.export(prepared.store, prepared.home, prepared.root, moves)
    }
  }

  @Test(arguments: ["manifest.json", "tasks", "tree"])
  func failedStageSyncPreservesPreviousTree(_ component: String) throws {
    try withScratchDirectory { scratch in
      let prepared = try ExportPublishTests.changeAndPrepare(scratch)
      let moves = ExportMoves(sync: { url in
        if url.lastPathComponent == component { throw StorageError.ioFailure }
        try ExportDurability.sync(url)
      })
      #expect(throws: ExportError.self) {
        try ExportPublishTests.export(prepared.store, prepared.home, prepared.root, moves)
      }
      #expect(try ExportServiceTests.tree(prepared.root.appending(path: "acme")) == prepared.before)
    }
  }

  @Test func failedPublicationSyncRetainsPreviousTreeAndSaysWritten() throws {
    try withScratchDirectory { scratch in
      let prepared = try ExportPublishTests.changeAndPrepare(scratch)
      let swapped = Mutex(false)
      let moves = ExportMoves(
        swap: { from, to in
          let result = renamex_np(from, to, UInt32(RENAME_SWAP))
          if result == 0 { swapped.withLock { $0 = true } }
          return result
        },
        sync: { url in
          if swapped.withLock({ $0 }) { throw StorageError.ioFailure }
          try ExportDurability.sync(url)
        })
      do {
        _ = try ExportPublishTests.export(prepared.store, prepared.home, prepared.root, moves)
        Issue.record("publication sync fault was ignored")
      } catch let error as any CodedError {
        let failure = error as? ExportFailure
        #expect(failure?.warnings.count == 1)
        let underlying = failure?.error ?? (error as? ExportError)
        guard case .publicationUnconfirmed(_, let work)? = underlying else {
          Issue.record("wrong failure: \(error)")
          return
        }
        #expect(error.message.contains("tree was written"))
        #expect(try ExportServiceTests.tree(URL(filePath: work + "/tree")) == prepared.before)
        #expect(
          try ExportServiceTests.tree(prepared.root.appending(path: "acme")) != prepared.before)
      }
    }
  }

  @Test func heldExportLockAnswersBusyAfterBoundedFakeWait() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let descriptor = open(home.appending(path: "export.lock").path, O_CREAT | O_RDWR, 0o600)
      #expect(descriptor >= 0)
      defer { close(descriptor) }
      #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let root = scratch.appending(path: "out")
      #expect(throws: ExportError.busy) {
        try ExportService.export(
          workspace: "acme", to: root, store: store, home: home, clock: clock)
      }
      #expect(abs(clock.now().timeIntervalSince(StorageSchemaTests.instant) - 5) < 0.00001)
      #expect(!FileManager.default.fileExists(atPath: root.path))
    }
  }
}
