import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension RestoreRefusalTests {
  @Test(
    arguments: ["workspace", "task_prefix", "repos", "apps", "topics", "services"], [false, true])
  func malformedIdentifiersLeaveTheStoreUnchanged(_ field: String, dryRun: Bool) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      var snapshot = try ExportTree.parse(ExportTreeTests.render(store))
      try Self.replaceIdentifier(field, in: &snapshot)
      let tree = try RestoreSupport.write(
        snapshot.files(), to: scratch.appending(path: "tree/acme"))
      try RestoreSupport.settle(store)
      let dump = try RestoreSupport.dump(store)
      let backups = try RestoreSupport.backups(home)
      let labels = [
        "workspace": "workspace slug", "task_prefix": "task prefix", "repos": "repo slug",
        "apps": "app slug", "topics": "topic slug", "services": "service slug",
      ]
      let label = try #require(labels[field])
      let refusal = ExportError.invalidRestoreIdentifier(field: label)
      #expect(throws: refusal) {
        try RestoreSupport.restore(tree, into: store, home: home, dryRun: dryRun)
      }
      #expect(try RestoreSupport.dump(store) == dump)
      #expect(try RestoreSupport.backups(home) == backups)
    }
  }

  @Test(arguments: [false, true])
  func taskSequenceMustLeaveRoomForTheNextRef(dryRun: Bool) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      var snapshot = try ExportTree.parse(ExportTreeTests.render(store))
      let index = try #require(snapshot.tasks.indices.last)
      let maximum = String(Int64.max)
      let ref = "AC-" + maximum
      snapshot.tasks[index].ref = ref
      snapshot.tasks[index].row =
        snapshot.tasks[index].row.replacing("seq", with: maximum, keys: ExportFormat.taskKeys)
        .replacing("ref", with: ref, keys: ExportFormat.taskKeys)
      let tree = try RestoreSupport.write(
        snapshot.files(), to: scratch.appending(path: "tree/acme"))
      try RestoreSupport.settle(store)
      let dump = try RestoreSupport.dump(store)
      let backups = try RestoreSupport.backups(home)
      #expect(
        throws: ExportError.invalidTree(
          reason: "a task sequence leaves no room for the next ref", workspace: "acme")
      ) {
        try RestoreSupport.restore(tree, into: store, home: home, dryRun: dryRun)
      }
      #expect(try RestoreSupport.dump(store) == dump)
      #expect(try RestoreSupport.backups(home) == backups)
    }
  }

  @Test(arguments: ["last-task", "counter", "padded", "destination"], [false, true])
  func computedTaskCounterMustLeaveRoomForTheNextRef(kind: String, dryRun: Bool) throws {
    try withScratchDirectory { scratch in
      let sourceHome = scratch.appending(path: "source")
      let source = try ExportFixture.make(sourceHome)
      var snapshot = try ExportTree.parse(ExportTreeTests.render(source))
      try Self.exhaustCounter(kind, in: &snapshot)
      let tree = try RestoreSupport.write(
        snapshot.files(), to: scratch.appending(path: "tree/acme"))
      let home = kind == "destination" ? sourceHome : scratch.appending(path: "empty")
      let store = kind == "destination" ? source : StorageSchemaTests.store(home)
      if kind == "destination" {
        try store.write { tx in
          try tx.database.execute(
            sql: "UPDATE seq_counter SET next=? WHERE scope='task:1'", arguments: [Int64.max])
        }
      }
      let before = kind == "destination" ? try RestoreSupport.dump(store) : nil
      let backups = try RestoreSupport.backups(home)
      let restoration = Result {
        try RestoreSupport.restore(tree, into: store, home: home, dryRun: dryRun)
      }
      let after = kind == "destination" ? try RestoreSupport.dump(store) : nil
      let published = try RestoreSupport.backups(home)
      let exists = FileManager.default.fileExists(atPath: store.path)
      withKnownIssue("Restore admits a task counter with no available next ref") {
        if case .failure(let error as any CodedError) = restoration {
          #expect(error.code == (kind == "destination" ? .conflict : .invalid))
          #expect(error.message.contains("counter"))
        } else {
          Issue.record("Expected a coded counter refusal.")
        }
        #expect(after == before)
        #expect(published == backups)
        #expect(exists == (kind == "destination"))
      }
    }
  }

  private static func exhaustCounter(_ kind: String, in snapshot: inout ExportSnapshot) throws {
    if kind == "last-task" {
      let index = try #require(snapshot.tasks.indices.last)
      let sequence = String(Int64.max - 1)
      let ref = "AC-" + sequence
      snapshot.tasks[index].ref = ref
      snapshot.tasks[index].row = snapshot.tasks[index].row
        .replacing("seq", with: sequence, keys: ExportFormat.taskKeys)
        .replacing("ref", with: ref, keys: ExportFormat.taskKeys)
    } else if kind == "counter" || kind == "padded" {
      let next = (kind == "padded" ? "0" : "") + String(Int64.max)
      snapshot.workspace = snapshot.workspace.replacing(
        "next_task_seq", with: next, keys: ExportFormat.workspaceKeys)
    }
  }

  private static func replaceIdentifier(_ field: String, in tree: inout ExportSnapshot) throws {
    switch field {
    case "workspace":
      tree.workspace = tree.workspace.replacing(
        "slug", with: "acme/research", keys: ExportFormat.workspaceKeys)
    case "task_prefix":
      tree.workspace = tree.workspace.replacing(
        "task_prefix", with: "AC/LAB", keys: ExportFormat.workspaceKeys)
      for index in tree.tasks.indices {
        let ref = "AC/LAB-" + (tree.tasks[index].row.value("seq") ?? "")
        tree.tasks[index].ref = ref
        tree.tasks[index].row = tree.tasks[index].row.replacing(
          "ref", with: ref, keys: ExportFormat.taskKeys)
      }
    default:
      let index = try #require(tree.sections.firstIndex { $0.name == field })
      let keys = ExportFormat.sections[index].keys
      let section = tree.sections[index]
      let row = try #require(section.rows.first)
      tree.sections[index].rows[0] = row.replacing("slug", with: "team/research", keys: keys)
    }
  }
}
