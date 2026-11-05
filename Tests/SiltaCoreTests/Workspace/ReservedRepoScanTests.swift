import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// The reserved `none` repo slug: one fixed name, and a refusal in place of a rebind.
@Suite(.timeLimit(.minutes(1)))
struct ReservedRepoScanTests {
  /// A `none` clone is always stored as `none-repo`, so a moved clone keeps its name
  /// and a rescan of its new path alone repoints that repo instead of another one.
  @Test func aMovedReservedCloneRebindsOnlyItsPath() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "old")
      let hidden = root.appending(path: ".none")
      let path = try ScanNamingTests.clone(hidden)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await ScanNamingTests.create(
        [root], slug: "work", prefix: "WK", store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(path, listed: hidden)))
      let created = try ScanNamingTests.repoPaths(store)
      #expect(created.map(\.slug) == ["none-repo"])
      #expect(created.map(\.path) == [path.path])

      let moved = home.appending(path: "new/.none")
      try FileManager.default.createDirectory(
        at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: hidden, to: moved)
      let movedPath = try RepositoryScanTests.path(moved)
      let outcome = try await RepositoryScan.scan(
        [moved], target: .rescan("work"), store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(movedPath, listed: moved)),
        identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      #expect(outcome.workspace == "work")
      let kept = try ScanNamingTests.repoPaths(store)
      #expect(kept.map(\.slug) == ["none-repo"])
      #expect(kept.map(\.path) == [movedPath.path])
    }
  }

  /// A `none` clone takes `none-repo`, and a workspace binding that name to a clone
  /// that still exists keeps it: the scan refuses and names both paths.
  @Test func aReservedNameBoundToALiveCloneIsRefused() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "scan")
      let literal = root.appending(path: "none-repo")
      let literalPath = try ScanNamingTests.clone(literal)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await ScanNamingTests.create(
        [root], slug: "work", prefix: "WK", store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(literalPath, listed: literal)))

      let hidden = home.appending(path: "other/.none")
      let hiddenPath = try ScanNamingTests.clone(hidden)
      let refusal = await ScanNamingTests.refusal {
        _ = try await RepositoryScan.scan(
          [hidden], target: .rescan("work"), store: store,
          git: ScriptedGitRunner(script: RepositoryScanTests.script(hiddenPath, listed: hidden)),
          identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      }
      let error = try #require(refusal)
      #expect(
        error as? ScanError
          == .reservedRepoBound(path: hiddenPath.path, bound: literalPath.path, workspace: "work")
      )
      #expect(error.message.contains(hiddenPath.path))
      #expect(error.message.contains(literalPath.path))
      #expect(error.code == .conflict)
      #expect(error.next == ["silta --ws 'work' init --scan '\(literalPath.path)'"])
      let kept = try ScanNamingTests.repoPaths(store)
      #expect(kept.map(\.slug) == ["none-repo"])
      #expect(kept.map(\.path) == [literalPath.path])
    }
  }

  /// A `none` clone and a literal `none-repo` clone would share one slug, so a scan
  /// that sees both is refused before either path is written.
  @Test func aNoneAndALiteralNoneRepoCannotShareOneScan() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "scan")
      let hidden = root.appending(path: ".none")
      let literal = root.appending(path: "none-repo")
      let hiddenPath = try ScanNamingTests.clone(hidden)
      let literalPath = try ScanNamingTests.clone(literal)
      let script =
        RepositoryScanTests.script(hiddenPath, listed: hidden)
        + RepositoryScanTests.script(literalPath, listed: literal)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      await #expect(throws: RepoError.duplicateSlug) {
        _ = try await ScanNamingTests.create(
          [root], slug: "work", prefix: "WK", store: store,
          git: ScriptedGitRunner(script: script))
      }
      #expect(try WorkspaceSelection.list(in: store).isEmpty)
    }
  }

  /// The same collision on a rescan is refused before any path is repointed.
  @Test func aLiteralNoneRepoAddedLaterIsRefusedOnRescan() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "scan")
      let hidden = root.appending(path: ".none")
      let hiddenPath = try ScanNamingTests.clone(hidden)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await ScanNamingTests.create(
        [root], slug: "work", prefix: "WK", store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(hiddenPath, listed: hidden)))
      let literal = root.appending(path: "none-repo")
      let literalPath = try ScanNamingTests.clone(literal)
      let script =
        RepositoryScanTests.script(hiddenPath, listed: hidden)
        + RepositoryScanTests.script(literalPath, listed: literal)
      await #expect(throws: RepoError.duplicateSlug) {
        _ = try await RepositoryScan.scan(
          [root], target: .rescan("work"), store: store, git: ScriptedGitRunner(script: script),
          identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      }
      let kept = try ScanNamingTests.repoPaths(store)
      #expect(kept.map(\.slug) == ["none-repo"])
      #expect(kept.map(\.path) == [hiddenPath.path])
    }
  }

}
