import Darwin
import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

struct ExportDurabilityTests {
  @Test func firstPublicationSyncFailureNamesAnEmptyWorkDirectoryAccurately() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let published = Mutex(false)
      let moves = ExportMoves(
        rename: { from, to in
          let result = Darwin.rename(from, to)
          if result == 0 { published.withLock { $0 = true } }
          return result
        },
        sync: { url in
          if published.withLock({ $0 }) { throw StorageError.ioFailure }
          try ExportDurability.sync(url)
        })
      do {
        _ = try ExportPublishTests.export(store, home, scratch.appending(path: "exports"), moves)
        Issue.record("publication sync failure was ignored")
      } catch let failure as ExportFailure {
        guard case .publicationUnconfirmed(_, let work) = failure.error else {
          Issue.record("wrong failure: \(failure)")
          return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work).isEmpty)
        #expect(failure.message.contains("work directory is retained"))
        #expect(!failure.message.contains("Recovery data"))
        let rendered = OutputRouter.render(
          .failure(failure), mode: OutputMode(json: true, quiet: false))
        let masked = rendered.stdout.replacingOccurrences(of: work, with: "<work>")
          .replacingOccurrences(of: scratch.path, with: "<scratch>")
          .replacingOccurrences(of: scratch.standardizedFileURL.path, with: "<scratch>")
        Golden.forTests().check(masked, "export-publication-unconfirmed.json")
      }
    }
  }

  @Test func filesAndDirectoriesAreSyncedBeforeSwap() throws {
    try withScratchDirectory { scratch in
      let prepared = try ExportPublishTests.changeAndPrepare(scratch)
      let synced = Mutex<[String]>([])
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
          let work = URL(filePath: from).deletingLastPathComponent().path
          let root = URL(filePath: to).deletingLastPathComponent().path
          let directories = [from + "/tasks", from, work, root]
          #expect(paths.filter { directories.contains($0) } == directories)
          synced.withLock { $0.append("published:" + from) }
          return renamex_np(from, to, UInt32(RENAME_SWAP))
        },
        sync: { url in
          try ExportDurability.sync(url)
          let publication = synced.withLock { $0.first { $0.hasPrefix("published:") } }
          if let publication {
            let previous = String(publication.dropFirst("published:".count))
            let bytes = try ExportServiceTests.tree(URL(filePath: previous))
            #expect(bytes == prepared.before)
          }
          synced.withLock { $0.append(url.path) }
        })
      _ = try ExportPublishTests.export(prepared.store, prepared.home, prepared.root, moves)
      let paths = synced.withLock { $0 }
      let publication = try #require(paths.firstIndex { $0.hasPrefix("published:") })
      let previous = String(paths[publication].dropFirst("published:".count))
      let work = URL(filePath: previous).deletingLastPathComponent()
      #expect(
        Array(paths.dropFirst(publication + 1)) == [
          work.path, prepared.root.standardizedFileURL.path,
        ])
      #expect(!FileManager.default.fileExists(atPath: work.path))
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

  @Test(arguments: ["work", "root"])
  func failedPublicationSyncRetainsPreviousTreeAndSaysWritten(_ failed: String) throws {
    try withScratchDirectory { scratch in
      let prepared = try ExportPublishTests.changeAndPrepare(scratch)
      let swapped = Mutex(false)
      let publicationSyncs = Mutex<[String]>([])
      let rootPath = prepared.root.standardizedFileURL.path
      let moves = ExportMoves(
        swap: { from, to in
          let result = renamex_np(from, to, UInt32(RENAME_SWAP))
          if result == 0 { swapped.withLock { $0 = true } }
          return result
        },
        sync: { url in
          if swapped.withLock({ $0 }) {
            let step = url.standardizedFileURL.path == rootPath ? "root" : "work"
            publicationSyncs.withLock { $0.append(step) }
            if step == failed { throw StorageError.ioFailure }
          }
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
        #expect(
          publicationSyncs.withLock { $0 } == (failed == "work" ? ["work"] : ["work", "root"]))
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
