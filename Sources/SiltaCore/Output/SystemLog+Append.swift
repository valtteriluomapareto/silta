import Darwin
package import Foundation

extension SystemLog {
  /// Appends one prepared daily record without following directory/file links or
  /// modifying a hardlinked target. Missing directories are created descriptor-relatively.
  package static func append(directory: URL, name: String, data: Data) throws {
    guard directory.path.hasPrefix("/"),
      name.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}\.jsonl/) != nil
    else {
      throw POSIXError(.EINVAL)
    }
    var parent = open("/", O_RDONLY | O_DIRECTORY)
    guard parent >= 0 else { throw POSIXError(.EIO) }
    defer { close(parent) }
    for component in directory.path.split(separator: "/") {
      guard component != ".", component != ".." else { throw POSIXError(.EINVAL) }
      let name = String(component)
      var child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      if child < 0, errno == ENOENT {
        guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw POSIXError(.EIO) }
        child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      }
      guard child >= 0 else { throw POSIXError(.EIO) }
      close(parent)
      parent = child
    }
    let descriptor = openat(
      parent, name, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
      throw POSIXError(.EINVAL)
    }
    try handle.write(contentsOf: data)
  }
}
