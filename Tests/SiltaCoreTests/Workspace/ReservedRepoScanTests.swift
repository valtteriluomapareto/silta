import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// `none` means non-code work, so a clone that normalizes to that slug is refused
/// rather than renamed.
@Suite(.timeLimit(.minutes(1)))
struct ReservedRepoScanTests {
  /// A scan that would create a workspace stops at the reserved clone, names its path,
  /// and writes nothing.
  @Test func aRepoNamedNoneIsRefused() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "scan")
      let none = root.appending(path: ".none")
      let literal = root.appending(path: "none-repo")
      let nonePath = try ScanNamingTests.clone(none)
      var script = RepositoryScanTests.script(nonePath, listed: none)
      script += RepositoryScanTests.script(try ScanNamingTests.clone(literal), listed: literal)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let refusal = await ScanNamingTests.refusal {
        _ = try await ScanNamingTests.create(
          [root], slug: "work", prefix: "WK", store: store,
          git: ScriptedGitRunner(script: script))
      }
      #expect(refusal as? ScanError == .reservedSlug(path: nonePath.path))
      #expect(refusal?.code == .conflict)
      #expect(refusal?.message.contains("--app none") == true)
      #expect(refusal?.message.contains(nonePath.path) == true)
      #expect(refusal?.next == ["silta init --help"])
      #expect(try WorkspaceSelection.list(in: store).isEmpty)
    }
  }

  /// A rescan refuses the same clone and leaves every stored binding as it was.
  @Test func aRepoNamedNoneIsRefusedOnRescan() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "scan")
      let literal = root.appending(path: "none-repo")
      let legacy = root.appending(path: "none-repo-2")
      let literalPath = try ScanNamingTests.clone(literal)
      let legacyPath = try ScanNamingTests.clone(legacy)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await ScanNamingTests.create(
        [root], slug: "work", prefix: "WK", store: store,
        git: ScriptedGitRunner(
          script: RepositoryScanTests.script(literalPath, listed: literal)
            + RepositoryScanTests.script(legacyPath, listed: legacy)))
      let none = root.appending(path: ".none")
      let nonePath = try ScanNamingTests.clone(none)
      let script =
        RepositoryScanTests.script(nonePath, listed: none)
        + RepositoryScanTests.script(literalPath, listed: literal)
        + RepositoryScanTests.script(legacyPath, listed: legacy)
      let refusal = await ScanNamingTests.refusal {
        _ = try await RepositoryScan.scan(
          [root], target: .rescan("work"), store: store, git: ScriptedGitRunner(script: script),
          identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      }
      #expect(refusal as? ScanError == .reservedSlug(path: nonePath.path))
      #expect(refusal?.code == .conflict)
      let kept = try ScanNamingTests.repoPaths(store)
      #expect(kept.map(\.slug) == ["none-repo", "none-repo-2"])
      #expect(kept.map(\.path) == [literalPath.path, legacyPath.path])
    }
  }

  /// A directory name is normalised before the reserved check, so a spelling that
  /// only normalises to `none` is refused just like the literal `none` and `.none`.
  @Test(arguments: ["None", "-none-"])
  func aRepoThatNormalizesToNoneIsRefused(_ name: String) async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "scan")
      let clone = root.appending(path: name)
      let path = try ScanNamingTests.clone(clone)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let refusal = await ScanNamingTests.refusal {
        _ = try await ScanNamingTests.create(
          [root], slug: "work", prefix: "WK", store: store,
          git: ScriptedGitRunner(script: RepositoryScanTests.script(path, listed: clone)))
      }
      #expect(refusal as? ScanError == .reservedSlug(path: path.path))
      #expect(refusal?.code == .conflict)
      #expect(try WorkspaceSelection.list(in: store).isEmpty)
    }
  }

  /// A no-option rescan of an existing workspace refuses the reserved clone too,
  /// and keeps every stored binding.
  @Test func aDerivedRescanRefusesTheReservedClone() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "work")
      let repo = root.appending(path: "acme")
      let repoPath = try ScanNamingTests.clone(repo)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await ScanNamingTests.create(
        [root], store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(repoPath, listed: repo)))
      let none = root.appending(path: ".none")
      let nonePath = try ScanNamingTests.clone(none)
      let script =
        RepositoryScanTests.script(nonePath, listed: none)
        + RepositoryScanTests.script(repoPath, listed: repo)
      let refusal = await ScanNamingTests.refusal {
        _ = try await ScanNamingTests.create(
          [root], store: store, git: ScriptedGitRunner(script: script))
      }
      #expect(refusal as? ScanError == .reservedSlug(path: nonePath.path))
      let kept = try ScanNamingTests.repoPaths(store)
      #expect(kept.map(\.slug) == ["acme"])
      #expect(kept.map(\.path) == [repoPath.path])
    }
  }

  /// A rescan names its workspace without regard to case, and still refuses the
  /// reserved clone.
  @Test(arguments: ["WORK", "Work"])
  func aDifferentlyCasedRescanRefusesTheReservedClone(_ spelling: String) async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "scan")
      let repo = root.appending(path: "acme")
      let repoPath = try ScanNamingTests.clone(repo)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await ScanNamingTests.create(
        [root], slug: "work", prefix: "WK", store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(repoPath, listed: repo)))
      let none = root.appending(path: ".none")
      let nonePath = try ScanNamingTests.clone(none)
      let script =
        RepositoryScanTests.script(nonePath, listed: none)
        + RepositoryScanTests.script(repoPath, listed: repo)
      let refusal = await ScanNamingTests.refusal {
        _ = try await RepositoryScan.scan(
          [root], target: .rescan(spelling), store: store,
          git: ScriptedGitRunner(script: script),
          identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      }
      #expect(refusal as? ScanError == .reservedSlug(path: nonePath.path))
      let kept = try ScanNamingTests.repoPaths(store)
      #expect(kept.map(\.slug) == ["acme"])
      #expect(kept.map(\.path) == [repoPath.path])
    }
  }

  /// The reserved name is refused before duplicate slugs are checked, so a scan
  /// carrying both reports the reserved clone rather than the duplicate.
  @Test func theReservedNameWinsOverADuplicateSlug() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "scan")
      let none = root.appending(path: ".none")
      let first = root.appending(path: "a/My Projects")
      let second = root.appending(path: "b/my projects")
      let nonePath = try ScanNamingTests.clone(none)
      var script = RepositoryScanTests.script(nonePath, listed: none)
      script += RepositoryScanTests.script(try ScanNamingTests.clone(first), listed: first)
      script += RepositoryScanTests.script(try ScanNamingTests.clone(second), listed: second)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let refusal = await ScanNamingTests.refusal {
        _ = try await ScanNamingTests.create(
          [root], slug: "work", prefix: "WK", store: store,
          git: ScriptedGitRunner(script: script))
      }
      #expect(refusal as? ScanError == .reservedSlug(path: nonePath.path))
      #expect(refusal?.code == .conflict)
      #expect(try WorkspaceSelection.list(in: store).isEmpty)
    }
  }
}
