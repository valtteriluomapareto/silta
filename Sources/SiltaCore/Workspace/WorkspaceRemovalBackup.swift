import Darwin
import Foundation

/// Makes fresh, admitted recovery data before the transaction removes a workspace.
enum WorkspaceRemovalBackup {
  static func make(
    _ slug: String, tx: StorageTransaction, home: URL, date: Date
  ) throws -> (backup: String, recovery: String) {
    let files = try ExportSnapshot.read(tx.database, workspace: slug).publicationFiles(
      workspace: slug)
    _ = try RestoreService.admit(files, directory: home, expected: slug)
    let parent = try DirectoryPath.open(home)
    defer { close(parent) }
    let prefix = "removed-workspace-"
    let leaf = try DirectoryPath.makeTemporary(in: parent, prefix: prefix)
    let work = home.appending(path: leaf)
    let fd = try DirectoryPath.open(leaf, in: parent)
    defer { close(fd) }
    let stage = ExportStage(work: work, parent: parent, directory: fd)
    let tree = work.appending(path: "tree")
    let token = leaf.dropFirst(prefix.count)
    let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
    let name = "silta-\(utcDay(date))-before-remove\(token)-\(milliseconds).db"
    do {
      guard stage.attached else { throw StorageError.ioFailure }
      try stage.write(files)
      try ExportDurability.stage(files, tree: tree, moves: stage.moves)
      let snapshot = try StorageBackup(home: home, file: tx.file).snapshot(
        name: name, staging: leaf, openedStage: fd)
      guard stage.attached else { throw StorageError.ioFailure }
      return (snapshot.path, tree.path)
    } catch {
      if stage.attached { try? stage.remove() }  // Only this attempt's private tree.
      throw error
    }
  }
}
