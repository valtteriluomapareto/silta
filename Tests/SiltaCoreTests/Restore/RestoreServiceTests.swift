import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RestoreServiceTests {
  @Test func restoresIntoAFreshHomeByteForByte() throws {
    try withScratchDirectory { scratch in
      let source = try ExportFixture.make(scratch.appending(path: "a"))
      let tree = try RestoreSupport.exportTree(source, to: scratch.appending(path: "tree"))
      let home = scratch.appending(path: "b")
      let target = ExportFixture.store(home)
      try target.initialize()
      let report = try RestoreSupport.restore(tree, into: target, home: home)
      #expect(report.created)
      #expect(report.tasks == .init(before: 0, after: 2))
      #expect(report.reposWithoutPath == ["platform", "notes"])
      #expect(report.snapshot == nil)
      ExportTreeTests.expectSame(
        try ExportTreeTests.render(target), try ExportTreeTests.render(source))
    }
  }

  @Test func restoresInPlaceKeepingMachineRowsAndOtherWorkspaces() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let before = try ExportTreeTests.render(store)
      let other = try ExportTreeTests.render(store, "other")
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      let report = try RestoreSupport.restore(tree, into: store, home: home)
      #expect(!report.created && report.sameUID)
      #expect(report.reposWithoutPath == ["notes"])
      #expect(report.removed.isEmpty && report.changed.isEmpty && report.claimsReplaced.isEmpty)
      let snapshot = try #require(report.snapshot)
      #expect(
        snapshot.hasPrefix(home.appending(path: "backups/silta-2023-11-14-before-restore-").path))
      ExportTreeTests.expectSame(try ExportTreeTests.render(store), before)
      ExportTreeTests.expectSame(try ExportTreeTests.render(store, "other"), other)
      let (id, paths, overrides, worktree, next) = try store.read { db in
        (
          try Int64.fetchOne(db, sql: "SELECT id FROM workspace WHERE slug='acme'"),
          try String.fetchAll(db, sql: "SELECT path FROM repo_path ORDER BY path"),
          try String.fetchAll(db, sql: "SELECT path FROM worktree_override"),
          try String.fetchOne(db, sql: "SELECT worktree FROM task WHERE seq=2"),
          try Int.fetchOne(db, sql: "SELECT next FROM seq_counter WHERE scope='task:1'")
        )
      }
      #expect(id == 1)
      #expect(paths == [ExportFixture.machinePaths[0]])
      #expect(overrides == [ExportFixture.machinePaths[1]])
      #expect(worktree == ExportFixture.machinePaths[2])
      #expect(next == 11)
    }
  }

  /// Seeded workspaces of every shape round-trip byte for byte, into a fresh home and
  /// in place. A failure names its seed.
  @Test(arguments: Array(UInt64(0)..<6))
  func generatedWorkspacesRoundTrip(seed: UInt64) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      var generator = RestoreGenerator(seed: seed)
      try DatabaseQueue(path: store.path).write { try generator.insert($0) }
      let exported = try ExportTreeTests.render(store)
      let tree = try RestoreSupport.write(exported, to: scratch.appending(path: "tree/acme"))
      let fresh = ExportFixture.store(scratch.appending(path: "b"))
      try fresh.initialize()
      _ = try RestoreSupport.restore(tree, into: fresh, home: scratch.appending(path: "b"))
      ExportTreeTests.expectSame(try ExportTreeTests.render(fresh), exported)
      _ = try RestoreSupport.restore(tree, into: store, home: home)
      ExportTreeTests.expectSame(try ExportTreeTests.render(store), exported)
    }
  }

  /// An older export replaces newer work, the report lists what is lost, and the task
  /// counter never rewinds, so refs already cited are never reused.
  @Test func olderTreeReportsLostWorkAndKeepsTheCounter() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      try DatabaseQueue(path: store.path).write { db in
        for seq in [11, 12] {
          try db.execute(
            sql: """
              INSERT INTO task(uid,workspace_id,seq,title,status,claimed_by,created_by,created_at,
                updated_at) VALUES(?,1,?,'Later work','doing','agent:codex:later','human:acme',
                '2023-11-15T00:00:00.000Z','2023-11-15T00:00:00.000Z')
              """, arguments: ["01HZLATE\(seq)", seq])
        }
        try db.execute(sql: "UPDATE task SET title='Renamed' WHERE seq=2")
        try db.execute(sql: "UPDATE seq_counter SET next=13 WHERE scope='task:1'")
        try db.execute(sql: #"UPDATE workspace SET settings='{"proposals":"triage"}' WHERE id=1"#)
      }
      let report = try RestoreSupport.restore(tree, into: store, home: home)
      #expect(report.tasks == .init(before: 4, after: 2))
      #expect(report.removed == ["AC-11", "AC-12"])
      #expect(report.changed == ["AC-2"])
      #expect(
        report.settings == [.init(key: "proposals", before: #""triage""#, after: #""ask""#)])
      #expect(
        report.claimsReplaced == [
          .init(task: "AC-11", actor: "agent:codex:later"),
          .init(task: "AC-12", actor: "agent:codex:later"),
        ])
      #expect(
        try store.read {
          try Int.fetchOne($0, sql: "SELECT next FROM seq_counter WHERE scope='task:1'")
        }
          == 13)
    }
  }

  /// Approvals are never deleted: rows written after the export survive, a row already
  /// present keeps its stored words, and an approved restore adds exactly its own row.
  @Test func approvalsMergeAndTheRestoreRecordsItsOwn() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      try DatabaseQueue(path: store.path).write { db in
        try db.execute(
          sql: "UPDATE approval SET words='kept words' WHERE uid='01HZAPRV000000000000000001'")
        try db.execute(
          sql: """
            INSERT INTO approval(uid,workspace,actor,command,words,created_at) VALUES
            ('01HZAPRVLATER','acme','agent:codex:acme','silta ws edit','later',
              '2023-11-15T00:00:00.000Z')
            """)
        try db.execute(sql: "DELETE FROM approval WHERE uid='01HZAPRV000000000000000009'")
      }
      let approval = try ActorID.agent(tool: "codex", session: "acme").requireHuman(
        command: "silta restore", approved: "yes, restore it")
      let report = try RestoreSupport.restore(tree, into: store, home: home, approval: approval)
      #expect(report.approvalsAdded == 1)
      try store.read { db in
        let rows = try Row.fetchAll(
          db, sql: "SELECT uid, words, command FROM approval WHERE workspace='acme' ORDER BY id")
        #expect(rows.count == 4)
        #expect(rows.contains { $0["uid"] == "01HZAPRVLATER" })
        #expect(rows.contains { $0["uid"] == "01HZAPRV000000000000000009" })
        #expect(rows.contains { $0["words"] == "kept words" })
        let own = try #require(rows.last)
        #expect(own["words"] == "yes, restore it")
        #expect(own["command"] == "silta restore manifest:\(report.manifestSHA256.prefix(12))")
      }
    }
  }

  @Test func dryRunReportsAndWritesNothing() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      try DatabaseQueue(path: store.path).write {
        try $0.execute(sql: "UPDATE task SET title='Renamed' WHERE seq=10")
      }
      try RestoreSupport.settle(store)
      let (dump, backups) = (try RestoreSupport.dump(store), try RestoreSupport.backups(home))
      let report = try RestoreSupport.restore(tree, into: store, home: home, dryRun: true)
      #expect(report.dryRun && report.changed == ["AC-10"] && report.snapshot == nil)
      #expect(try RestoreSupport.dump(store) == dump)
      #expect(try RestoreSupport.backups(home) == backups)
    }
  }

  /// A tree of an older schema lacks the keys later migrations added; they restore as
  /// their column defaults (spec §15).
  @Test func olderSchemaTreeRestoresLaterColumnsAtTheirDefaults() throws {
    try withScratchDirectory { scratch in
      let source = try ExportFixture.make(scratch.appending(path: "a"))
      var files = try ExportTreeTests.render(source)
      for path in ["tasks/AC-2.md", "tasks/AC-10.md"] {
        let lines = text(try #require(files[path])).split(
          separator: "\n", omittingEmptySubsequences: false)
        files[path] = Data(
          lines.filter { !$0.hasPrefix("follow_up_at: ") }.joined(separator: "\n").utf8)
        TreeDamage.rehash(&files, path)
      }
      let manifest = text(try #require(files["manifest.json"]))
      files["manifest.json"] = Data(
        manifest.replacingOccurrences(of: #""schema": "v4""#, with: #""schema": "v3""#).utf8)
      let tree = try RestoreSupport.write(files, to: scratch.appending(path: "tree/acme"))
      let home = scratch.appending(path: "b")
      let target = ExportFixture.store(home)
      try target.initialize()
      _ = try RestoreSupport.restore(tree, into: target, home: home)
      #expect(
        try target.read {
          try Int.fetchOne($0, sql: "SELECT count(*) FROM task WHERE follow_up_at IS NULL")
        }
          == 2)
    }
  }

  @Test func taskWorktreeIsKeptOnlyForTheSameClaim() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      try DatabaseQueue(path: store.path).write {
        try $0.execute(sql: "UPDATE task SET claimed_by='agent:claude:other' WHERE seq=2")
      }
      _ = try RestoreSupport.restore(tree, into: store, home: home)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT worktree FROM task WHERE seq=2") }
          == nil)
    }
  }

  @Test func changeLogNamesTheWorkspaceAndEveryTask() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      _ = try RestoreSupport.restore(tree, into: store, home: home)
      try store.read { db in
        let kinds = try String.fetchAll(db, sql: "SELECT kind FROM change_log")
        #expect(kinds.filter { $0 == "workspace" }.count == 1)
        #expect(kinds.filter { $0 == "task" }.count == 4)
        #expect(kinds.filter { $0 == "comment" }.count == 4)
      }
    }
  }
}
