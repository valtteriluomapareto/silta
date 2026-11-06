import Darwin
import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

struct ExportRootDurabilityTests {
  @Test func retryThroughRootAliasFlushesResolvedAncestors() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let actual = scratch.appending(path: "actual")
      let root = actual.appending(path: "new-parent/exports")
      let failed = ExportMoves(sync: { url in
        if url.standardizedFileURL.path == actual.standardizedFileURL.path {
          throw StorageError.ioFailure
        }
        try ExportDurability.sync(url)
      })
      #expect(throws: ExportError.self) {
        try ExportPublishTests.export(store, home, root, failed)
      }
      let alias = scratch.appending(path: "alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
      let synced = Mutex<[String]>([])
      let retry = ExportMoves(sync: { url in
        try ExportDurability.sync(url)
        synced.withLock { $0.append(url.standardizedFileURL.path) }
      })
      _ = try ExportPublishTests.export(store, home, alias, retry)
      let paths = synced.withLock { $0 }
      #expect(paths.contains(actual.standardizedFileURL.path))
      #expect(paths.contains(root.deletingLastPathComponent().standardizedFileURL.path))
    }
  }

  @Test func ancestorFailureStillReportsExistingWorkDirectories() throws {

    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports").standardizedFileURL
      let leftover = root.appending(path: ".acme.export-retained")
      try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
      let moves = ExportMoves(sync: { url in
        if url.standardizedFileURL == scratch.standardizedFileURL {
          throw StorageError.ioFailure
        }
        try ExportDurability.sync(url)
      })
      do {
        _ = try ExportPublishTests.export(store, home, root, moves)
        Issue.record("the ancestor flush fault was ignored")
      } catch let failure as ExportFailure {
        #expect(failure.warnings.map(\.code) == ["export_leftover"])
        #expect(
          failure.leftovers.map { URL(filePath: $0.path).lastPathComponent } == [
            leftover.lastPathComponent
          ])
      }
    }

  }

  @Test func newRootAncestorNamesAreSyncedBeforePublication() throws {

    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "new-parent/exports").standardizedFileURL
      let synced = Mutex<[String]>([])
      let moves = ExportMoves(
        rename: { from, to in
          let parent = URL(filePath: to).deletingLastPathComponent().deletingLastPathComponent()
          let components = parent.pathComponents
          let required = components.indices.reversed().map {
            NSString.path(withComponents: Array(components.prefix($0 + 1)))
          }
          let ancestors = synced.withLock { $0.filter { required.contains($0) } }
          #expect(ancestors == required)
          return Darwin.rename(from, to)
        },
        sync: { url in
          try ExportDurability.sync(url)
          synced.withLock { $0.append(url.path) }
        })
      _ = try ExportPublishTests.export(store, home, root, moves)
    }

  }

  @Test(arguments: ["new-parent", "scratch"])
  func ancestorFlushFailureRefusesBeforePublication(_ failed: String) throws {

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

  @Test func retryFlushesAncestorsLeftByFailedPreparation() throws {

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
