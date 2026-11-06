import Darwin
import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// What export says about the trees it leaves behind and the targets it refuses.
@Suite(.timeLimit(.minutes(1)))
struct ExportLeftoverTests {
  /// Runs `command` through the shell, as a human following `next` would.
  static func shell(_ command: String) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", command]
    try process.run()
    process.waitUntilExit()
  }

  /// No swap; the new tree's rename and the move back both fail. With `recreate`,
  /// another export puts a tree at the target in between, as in the shared-volume race.
  static func stuck(recreate: Bool) -> ExportMoves {
    ExportMoves(
      swap: ExportPublishTests.noSwap.swap,
      rename: { from, to in
        guard from.contains(".acme.export-") else { return Darwin.rename(from, to) }
        if recreate && from.hasSuffix("/tree") {
          try? FileManager.default.createDirectory(  // the other export's tree
            atPath: to, withIntermediateDirectories: false)
        }
        errno = EIO
        return -1
      })
  }

  /// The printed `next` is safe while the target is back, and restores the
  /// previous tree while it is absent.
  @Test(arguments: [false, true])
  func previousKeptNextIsSafeWhetherOrNotTheTargetCameBack(_ recreate: Bool) throws {
    do {
      try withScratchDirectory { scratch in
        let prepared = try ExportPublishTests.changeAndPrepare(scratch)
        let target = prepared.root.appending(path: "acme")
        var thrown: ExportError?
        do {
          _ = try ExportPublishTests.export(
            prepared.store, prepared.home, prepared.root, Self.stuck(recreate: recreate))
        } catch let error as ExportError {
          thrown = error
        } catch let failure as ExportFailure {
          thrown = failure.error
        }
        let error = try #require(thrown)
        #expect(error.next.count == 1 && error.next[0].hasPrefix("[ ! -e "), "\(error.next)")
        try Self.shell(error.next.joined())
        let tree = try ExportServiceTests.tree(target)
        if recreate {
          #expect(tree.isEmpty, "the other export's target was changed")
        } else {
          #expect(tree == prepared.before)
        }
      }
    }
  }

  /// A kept work directory says where the replaced tree is and what export did not
  /// write, after an atomic swap and after the fallback alike.
  @Test(arguments: [true, false])
  func aKeptTreeNamesTheFileExportDidNotWrite(_ atomic: Bool) throws {
    do {
      try withScratchDirectory { scratch in
        let prepared = try ExportPublishTests.changeAndPrepare(scratch)
        let appearing = ExportMoves(swap: { from, to in
          FileManager.default.createFile(atPath: to + "/human-notes.md", contents: Data("A".utf8))
          if atomic { return renamex_np(from, to, UInt32(RENAME_SWAP)) }
          errno = ENOTSUP
          return -1
        })
        let result = try ExportPublishTests.export(
          prepared.store, prepared.home, prepared.root, appearing)
        let kept = try #require(result.leftovers.first)
        let held = atomic ? "tree" : "previous"
        #expect(kept.reason.contains("\(held)/") && kept.reason.contains("human-notes.md"))
        #expect(FileManager.default.fileExists(atPath: kept.path + "/\(held)/human-notes.md"))
      }
    }
  }

  /// A work directory that can't be removed is reported.
  @Test func aWorkDirectoryThatCannotBeRemovedIsReported() throws {
    try withScratchDirectory { scratch in
      let prepared = try ExportPublishTests.changeAndPrepare(scratch)
      let tasks = prepared.root.appending(path: "acme/tasks")
      try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tasks.path)
      let result = try ExportPublishTests.export(
        prepared.store, prepared.home, prepared.root, ExportMoves())
      let kept = try #require(result.leftovers.first)
      #expect(kept.reason == "could not be removed")
      try? FileManager.default.setAttributes(  // best-effort, so the scratch can be removed
        [.posixPermissions: 0o700], ofItemAtPath: kept.path + "/tree/tasks")
    }
  }

  /// Leftovers are reported with a failure too.
  @Test func aFailureStillReportsLeftovers() throws {
    do {
      try withScratchDirectory { scratch in
        let prepared = try ExportPublishTests.changeAndPrepare(scratch)
        let leftover = prepared.root.appending(path: ".acme.export-a1b2c3")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        do {
          _ = try ExportPublishTests.export(
            prepared.store, prepared.home, prepared.root, ExportPublishTests.failsIn)
          Issue.record("the failing swap succeeded")
        } catch let failure as ExportFailure {
          #expect(failure.warnings.map(\.code) == ["export_leftover"])
          #expect(
            failure.leftovers.map(\.path).contains(leftover.path) || failure.warnings.count == 1)
        }
      }
    }
  }

  /// An unreadable root cannot be synced before publication; the refusal still warns
  /// that leftover work directories could not be listed.
  @Test func anUnlistableRootIsRefusedWithALeftoverWarning() throws {
    do {
      try withScratchDirectory { scratch in
        let home = scratch.appending(path: "home")
        let store = try ExportFixture.make(home)
        let root = scratch.appending(path: "exports")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: root.path)
        defer {
          try? FileManager.default.setAttributes(  // best-effort, so the scratch can be removed
            [.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        do {
          _ = try ExportServiceTests.export(store, home, to: root)
          Issue.record("an unsyncable root was published")
        } catch let failure as ExportFailure {
          #expect(failure.error == .unwritable(path: root.path, workspace: "acme"))
          #expect(failure.leftovers.map(\.reason) == ["could not be listed for work directories"])
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "acme").path))
      }
    }
  }

  /// Refusals name their real cause.
  @Test(arguments: ["manifest", "target"])
  func unreadableTargetsAreRefusedForTheRightCause(_ what: String) throws {
    do {
      try withScratchDirectory { scratch in
        let home = scratch.appending(path: "home")
        let store = try ExportFixture.make(home)
        let root = scratch.appending(path: "exports")
        _ = try ExportServiceTests.export(store, home, to: root)
        let path = root.appending(path: what == "manifest" ? "acme/manifest.json" : "acme").path
        try FileManager.default.setAttributes(
          [.posixPermissions: what == "manifest" ? 0o000 : 0o300], ofItemAtPath: path)
        defer {
          try? FileManager.default.setAttributes(  // best-effort, so the scratch can be removed
            [.posixPermissions: 0o700], ofItemAtPath: path)
        }
        do {
          _ = try ExportServiceTests.export(store, home, to: root)
          Issue.record("an unreadable \(what) was replaced")
        } catch let error as ExportError {
          let cause = what == "manifest" ? "its manifest.json can't be read" : "it can't be read"
          #expect(error.message.contains(cause), "\(error.message)")
        }
      }
    }
  }
}
