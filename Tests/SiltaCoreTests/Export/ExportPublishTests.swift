import Darwin
import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

/// How export puts a tree in place and what it leaves: the fallback for volumes without
/// an atomic swap, unreadable targets, and work directories it doesn't remove.
@Suite(.timeLimit(.minutes(1)))
struct ExportPublishTests {
  /// A volume like exFAT or SMB: the swap is unsupported.
  static let noSwap = ExportMoves(swap: { _, _ in
    errno = ENOTSUP
    return -1
  })

  /// No swap, and every rename out of the work directory fails, the move back included.
  static let stuck = ExportMoves(
    swap: noSwap.swap,
    rename: { from, to in
      guard !from.contains(".acme.export-") else {
        errno = EIO
        return -1
      }
      return Darwin.rename(from, to)
    })

  /// No swap, and only the new tree's rename fails; the old tree moves back.
  static let failsIn = ExportMoves(
    swap: noSwap.swap,
    rename: { from, to in
      guard !from.hasSuffix("/tree") else {
        errno = EIO
        return -1
      }
      return Darwin.rename(from, to)
    })

  static func export(_ store: DatabaseStore, _ home: URL, _ root: URL, _ moves: ExportMoves)
    throws -> ExportResult
  {
    try ExportService.export(workspace: "acme", to: root, store: store, home: home, moves: moves)
  }

  /// An exported fixture whose database then changes, so the next export replaces it.
  struct Prepared {
    let store: DatabaseStore
    let home: URL
    let root: URL
    let before: [String: Data]
  }

  static func changeAndPrepare(_ scratch: URL) throws -> Prepared {
    let home = scratch.appending(path: "home")
    let store = try ExportFixture.make(home)
    let root = scratch.appending(path: "exports")
    _ = try ExportServiceTests.export(store, home, to: root)
    let before = try ExportServiceTests.tree(root.appending(path: "acme"))
    try DatabaseQueue(path: store.path).write {
      try $0.execute(sql: "UPDATE task SET title='Renamed' WHERE seq=2")
    }
    return Prepared(store: store, home: home, root: root, before: before)
  }

  @Test func withoutAnAtomicSwapTheTreeIsStillReplaced() throws {
    try withScratchDirectory { scratch in
      let prepared = try Self.changeAndPrepare(scratch)
      let (store, home, root) = (prepared.store, prepared.home, prepared.root)
      let result = try Self.export(store, home, root, Self.noSwap)
      #expect(result.leftovers.isEmpty)
      ExportTreeTests.expectSame(
        try ExportServiceTests.tree(root.appending(path: "acme")), try ExportTreeTests.render(store)
      )
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["acme"])
    }
  }

  @Test func aFailedFallbackPutsThePreviousTreeBack() throws {
    try withScratchDirectory { scratch in
      let prepared = try Self.changeAndPrepare(scratch)
      let (store, home, root) = (prepared.store, prepared.home, prepared.root)
      let before = prepared.before
      #expect(throws: ExportError.self) { try Self.export(store, home, root, Self.failsIn) }
      #expect(try ExportServiceTests.tree(root.appending(path: "acme")) == before)
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["acme"])
    }
  }

  /// When the previous tree can't be moved back either, it is kept and named, never
  /// removed with the work directory.
  @Test func aStuckFallbackKeepsThePreviousTreeAndNamesIt() throws {
    try withScratchDirectory { scratch in
      let prepared = try Self.changeAndPrepare(scratch)
      let (store, home, root) = (prepared.store, prepared.home, prepared.root)
      let before = prepared.before
      do {
        _ = try Self.export(store, home, root, Self.stuck)
        Issue.record("the stuck swap succeeded")
      } catch let error as ExportError {
        guard case .previousKept(let path, _, _) = error else {
          Issue.record("\(error)")
          return
        }
        #expect(error.nextBy == .human)
        #expect(try ExportServiceTests.tree(URL(filePath: path)) == before)
      }
    }
  }

  /// A target holding an entry export can't read is refused, not treated as empty.
  @Test(arguments: [0o000, 0o300])
  func unreadableEntriesAreRefused(_ mode: Int) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      let locked = root.appending(path: "acme/locked")
      try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
      try Data("Acme".utf8).write(to: locked.appending(path: "s.txt"))
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: locked.path)
      defer {
        try? FileManager.default.setAttributes(  // best-effort, so the scratch can be removed
          [.posixPermissions: 0o700], ofItemAtPath: locked.path)
      }
      #expect(throws: ExportError.self) { try ExportServiceTests.export(store, home, to: root) }
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["acme"])
    }
  }

  /// A file that appears in the target while the new tree is written is not export's:
  /// the swapped-out tree is kept with it and reported.
  @Test func aFileThatAppearsMeanwhileIsKeptAndReported() throws {
    try withScratchDirectory { scratch in
      let prepared = try Self.changeAndPrepare(scratch)
      let (store, home, root) = (prepared.store, prepared.home, prepared.root)
      let appearing = ExportMoves(swap: { from, to in
        FileManager.default.createFile(atPath: to + "/conflict copy.md", contents: Data("A".utf8))
        return renamex_np(from, to, UInt32(RENAME_SWAP))
      })
      let result = try Self.export(store, home, root, appearing)
      let kept = try #require(result.leftovers.first?.path)
      #expect(FileManager.default.fileExists(atPath: kept + "/tree/conflict copy.md"))
      ExportTreeTests.expectSame(
        try ExportServiceTests.tree(root.appending(path: "acme")), try ExportTreeTests.render(store)
      )
    }
  }

  @Test func aCrashedExportsWorkDirectoryIsReportedNotRemoved() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      let leftover = root.appending(path: ".acme.export-a1b2c3/tree")
      try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
      let result = try ExportServiceTests.export(store, home, to: root)
      #expect(
        result.leftovers.map { URL(filePath: $0.path).lastPathComponent } == [".acme.export-a1b2c3"]
      )
      #expect(FileManager.default.fileExists(atPath: leftover.path))
    }
  }

  @Test func rootIdentityChangeRefusesBeforePublication() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      let moved = scratch.appending(path: "moved-exports")
      let attempted = Mutex(false)
      let moves = ExportMoves(
        rename: { _, _ in
          attempted.withLock { $0 = true }
          return -1
        },
        sync: { path in
          if path.lastPathComponent == "tree" {
            let fm = FileManager.default
            try fm.moveItem(at: root, to: moved)
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
          }
        })
      #expect(throws: ExportError.self) {
        try ExportService.export(
          workspace: "acme", to: root, store: store, home: home, moves: moves)
      }
      #expect(!attempted.withLock { $0 })
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: moved.path).contains {
          $0.hasPrefix(".acme.export-")
        })
    }
  }

  /// Each work directory is new and exclusively created, so it can never be someone
  /// else's directory under a predictable name.
  @Test func workDirectoriesAreNewAndDistinct() throws {
    try withScratchDirectory { scratch in
      let parent = try DirectoryPath.open(scratch)
      defer { close(parent) }
      let first = try DirectoryPath.makeTemporary(in: parent, prefix: ".acme.export-")
      let second = try DirectoryPath.makeTemporary(in: parent, prefix: ".acme.export-")
      #expect(first != second)
      for name in [first, second] {
        #expect(name.hasPrefix(".acme.export-"))
        let directory = scratch.appending(path: name)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
      }
    }
  }
}
