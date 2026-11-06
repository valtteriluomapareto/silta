import Darwin
import Foundation
import SiltaCore

/// Bounded inspection without following a configuration or log directory symlink.
enum AgentHealthFiles {
  static func read(root: String, path: String) throws -> String? {
    guard root.hasPrefix("/"),
      !root.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else {
      throw TaskError.input
    }
    var directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    if directory < 0, errno == ENOENT { return nil }
    guard directory >= 0 else { throw TaskError.input }
    defer { close(directory) }
    for component in path.split(separator: "/").dropLast() {
      let child = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      if child < 0, errno == ENOENT { return nil }
      guard child >= 0 else { throw TaskError.input }
      close(directory)
      directory = child
    }
    let fd = openat(
      directory, URL(filePath: path).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0, errno == ENOENT { return nil }
    guard fd >= 0 else { throw TaskError.input }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size <= AgentInstallFiles.maximumBytes
    else { throw TaskError.input }
    let data = try handle.read(upToCount: AgentInstallFiles.maximumBytes + 1) ?? Data()
    var after = stat()
    guard fstat(fd, &after) == 0, after.st_size == info.st_size,
      data.count == info.st_size, data.count <= AgentInstallFiles.maximumBytes,
      let text = String(data: data, encoding: .utf8)
    else { throw TaskError.input }
    return text
  }
}
