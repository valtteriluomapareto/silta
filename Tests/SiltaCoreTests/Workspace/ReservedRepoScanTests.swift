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
}
