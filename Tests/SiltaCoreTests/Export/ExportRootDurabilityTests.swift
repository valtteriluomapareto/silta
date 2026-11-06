import Darwin
import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

struct ExportRootDurabilityTests {
  @Test func newRootAncestorNamesAreSyncedBeforePublication() throws {
    withKnownIssue("#14: export pathname ancestors are not flushed") {
      try withScratchDirectory { scratch in
        let home = scratch.appending(path: "home")
        let store = try ExportFixture.make(home)
        let root = scratch.appending(path: "new-parent/exports").standardizedFileURL
        let synced = Mutex<[String]>([])
        let moves = ExportMoves(
          rename: { from, to in
            let parent = URL(filePath: to).deletingLastPathComponent().deletingLastPathComponent()
            let components = parent.standardizedFileURL.pathComponents
            let required = components.indices.reversed().map {
              NSString.path(withComponents: Array(components.prefix($0 + 1)))
            }
            let ancestors = synced.withLock { $0.filter { required.contains($0) } }
            #expect(ancestors == required)
            return Darwin.rename(from, to)
          },
          sync: { url in
            try ExportDurability.sync(url)
            synced.withLock { $0.append(url.standardizedFileURL.path) }
          })
        _ = try ExportPublishTests.export(store, home, root, moves)
      }
    }
  }

  @Test(arguments: ["new-parent", "scratch"])
  func ancestorFlushFailureRefusesBeforePublication(_ failed: String) throws {
    withKnownIssue("#14: export pathname ancestors are not flushed") {
      try withScratchDirectory { scratch in
        let home = scratch.appending(path: "home")
        let store = try ExportFixture.make(home)
        let sibling = scratch.appending(path: "keep.txt")
        try Data("Acme".utf8).write(to: sibling)
        let root = scratch.appending(path: "new-parent/exports").standardizedFileURL
        let fault =
          failed == "scratch" ? scratch.standardizedFileURL : root.deletingLastPathComponent()
        let moves = ExportMoves(sync: { url in
          if url.standardizedFileURL == fault.standardizedFileURL { throw StorageError.ioFailure }
          try ExportDurability.sync(url)
        })
        #expect(throws: ExportError.unwritable(path: root.path, workspace: "acme")) {
          try ExportPublishTests.export(store, home, root, moves)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "acme").path))
        #expect(try Data(contentsOf: sibling) == Data("Acme".utf8))
      }
    }
  }

  @Test func retryFlushesAncestorsLeftByFailedPreparation() throws {
    withKnownIssue("#14: export pathname ancestors are not flushed") {
      try withScratchDirectory { scratch in
        let home = scratch.appending(path: "home")
        let store = try ExportFixture.make(home)
        let root = scratch.appending(path: "new-parent/exports").standardizedFileURL
        let scratchPath = scratch.standardizedFileURL.path
        let failed = ExportMoves(sync: { url in
          if url.standardizedFileURL.path == scratchPath { throw StorageError.ioFailure }
          try ExportDurability.sync(url)
        })
        #expect(throws: ExportError.self) {
          try ExportPublishTests.export(store, home, root, failed)
        }
        let synced = Mutex<[String]>([])
        let retry = ExportMoves(sync: { url in
          try ExportDurability.sync(url)
          synced.withLock { $0.append(url.standardizedFileURL.path) }
        })
        _ = try ExportPublishTests.export(store, home, root, retry)
        let paths = synced.withLock { $0 }
        #expect(paths.contains(root.deletingLastPathComponent().standardizedFileURL.path))
        #expect(paths.contains(scratchPath))
        #expect(paths.contains("/"))
      }
    }
  }
}
