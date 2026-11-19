import Darwin
import Foundation

extension StorageBackup {
  /// With the manual lock held, removes interrupted staging in both managed locations.
  func cleanManualStaging() throws {
    let parent = try DirectoryPath.open(home)
    defer { close(parent) }
    let directory = try DirectoryPath.open("backups", in: parent, creating: true)
    defer { close(directory) }
    try Self.removeManualStaging(in: directory)
    try Self.removeManualStaging(in: parent)
  }

  private static func removeManualStaging(in parent: Int32) throws {
    for name in try DirectoryPath.names(in: parent)
    where name.wholeMatch(of: /\.manual-[A-Za-z0-9]{6}/) != nil {
      let opened = try? DirectoryPath.open(name, in: parent)  // may be unrelated or unreadable
      guard let opened else { continue }
      defer { close(opened) }
      let names = try DirectoryPath.names(in: opened)
      guard
        names.isEmpty
          || (names == ["snapshot.pending"]
            && regularSize("snapshot.pending", in: opened) != nil)
      else { continue }
      if !names.isEmpty {
        guard unlinkat(opened, "snapshot.pending", 0) == 0 else { continue }
      }
      _ = unlinkat(parent, name, AT_REMOVEDIR)
    }
  }
}
