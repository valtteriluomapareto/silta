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
    let parent = try DirectoryPath.open(directory, creating: true)
    defer { close(parent) }
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
