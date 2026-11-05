import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// What keeps a restore from reusing refs, touching a workspace on a dry run, or
/// restoring a tree the human did not approve.
@Suite(.timeLimit(.minutes(1)))
struct RestoreSafetyTests {
  /// The tree's counter is kept when it is above every task's seq: refs of tasks
  /// deleted before the export are never reused on the new machine.
  @Test func treeCounterAboveTheHighestSeqIsKept() throws {
    try withScratchDirectory { scratch in
      let source = try ExportFixture.make(scratch.appending(path: "a"))
      try DatabaseQueue(path: source.path).write {
        try $0.execute(sql: "UPDATE seq_counter SET next=50 WHERE scope='task:1'")
      }
      let tree = try RestoreSupport.exportTree(source, to: scratch.appending(path: "tree"))
      let home = scratch.appending(path: "b")
      let target = ExportFixture.store(home)
      try target.initialize()
      _ = try RestoreSupport.restore(tree, into: target, home: home)
      #expect(
        try target.read { try Int.fetchOne($0, sql: "SELECT next FROM seq_counter") } == 50)
    }
  }

  /// A dry run never changes a workspace, also into a home that has none.
  @Test func dryRunIntoAFreshHomeCreatesNoWorkspace() throws {
    try withScratchDirectory { scratch in
      let source = try ExportFixture.make(scratch.appending(path: "a"))
      let tree = try RestoreSupport.exportTree(source, to: scratch.appending(path: "tree"))
      let home = scratch.appending(path: "b")
      let target = ExportFixture.store(home)
      let report = try RestoreSupport.restore(tree, into: target, home: home, dryRun: true)
      #expect(report.created && report.dryRun)
      #expect(try target.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 0)
    }
  }

  /// The approval names the tree the human saw: another manifest is refused.
  @Test func aChangedTreeIsRefusedAgainstTheApprovedManifest() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      let dump = try RestoreSupport.dump(store)
      #expect(throws: ExportError.self) {
        try RestoreSupport.restore(tree, into: store, home: home, manifest: "000000000000")
      }
      #expect(try RestoreSupport.dump(store) == dump)
      let report = try RestoreSupport.restore(tree, into: store, home: home, dryRun: true)
      _ = try RestoreSupport.restore(
        tree, into: store, home: home, manifest: String(report.manifestSHA256.prefix(12)))
    }
  }
}
