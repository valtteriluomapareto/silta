import Darwin
import Foundation

/// Private staging inside the opened export root. Relative operations survive a
/// pathname replacement without writing through its new value.
struct ExportStage {
  let work: URL
  let parent: Int32
  let directory: Int32

  func write(_ files: [String: Data]) throws {
    let tree = try DirectoryPath.open("tree", in: directory, creating: true)
    defer { close(tree) }
    for (path, data) in files { try Self.write(data, to: path, in: tree) }
  }

  private static func write(_ data: Data, to path: String, in tree: Int32) throws {
    let parts = path.split(separator: "/")
    guard let name = parts.last else { throw POSIXError(.EINVAL) }
    var parent = fcntl(tree, F_DUPFD_CLOEXEC, 0)
    guard parent >= 0 else { throw DirectoryPath.failure() }
    defer { close(parent) }
    for part in parts.dropLast() {
      let child = try DirectoryPath.open(String(part), in: parent, creating: true)
      close(parent)
      parent = child
    }
    let descriptor = openat(
      parent, String(name), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw DirectoryPath.failure() }
    defer { close(descriptor) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    try handle.write(contentsOf: data)
  }

  func remove() throws {
    guard removefileat(parent, work.lastPathComponent, nil, UInt32(REMOVEFILE_RECURSIVE)) == 0
    else { throw DirectoryPath.failure() }
  }

  /// Uses the stage descriptor for its two tree names and the root for the workspace.
  var moves: ExportMoves {
    let parent = parent
    let directory = directory
    let workPath = work.path
    @Sendable func endpoint(_ path: String) -> (Int32, String) {
      let url = URL(filePath: path)
      let withinWork = url.deletingLastPathComponent().path == workPath
      return (withinWork ? directory : parent, url.lastPathComponent)
    }
    return ExportMoves(
      swap: { from, to in
        let a = endpoint(from)
        let b = endpoint(to)
        return renameatx_np(a.0, a.1, b.0, b.1, UInt32(RENAME_SWAP))
      },
      rename: { from, to in
        let a = endpoint(from)
        let b = endpoint(to)
        return renameat(a.0, a.1, b.0, b.1)
      })
  }
}
