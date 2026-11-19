import Foundation
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
