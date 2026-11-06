import Darwin
import Foundation

/// Flushes staged bytes and names before publication and the rename before retirement.
enum ExportDurability {
  /// Flushes the pathname's dependencies on every attempt. An existing directory
  /// may have survived an earlier preparation failure without its name being flushed.
  /// Both chains matter when that path is retried through a root alias.
  static func syncAncestors(of root: URL, moves: ExportMoves) throws {
    var synced: Set<String> = []
    for path in [root, root.resolvingSymlinksInPath()] {
      var parent = path.deletingLastPathComponent()
      while synced.insert(parent.path).inserted {
        try moves.sync(parent)
        let ancestor = parent.deletingLastPathComponent()
        if ancestor == parent { break }
        parent = ancestor
      }
    }
  }

  static func sync(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw StorageError.ioFailure }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw StorageError.ioFailure }
  }

  static func stage(_ files: [String: Data], tree: URL, moves: ExportMoves) throws {
    var directories: Set<URL> = [tree]
    for path in files.keys.sorted() {
      let file = tree.appending(path: path)
      try moves.sync(file)
      var parent = file.deletingLastPathComponent()
      while parent.path.hasPrefix(tree.path + "/") {
        directories.insert(parent)
        parent = parent.deletingLastPathComponent()
      }
    }
    for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
      try moves.sync(directory)
    }
    try moves.sync(tree.deletingLastPathComponent())
    try moves.sync(tree.deletingLastPathComponent().deletingLastPathComponent())
  }
}
