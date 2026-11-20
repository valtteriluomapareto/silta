import Darwin
import Foundation

/// The regular file and resolved name a SQLite connection was opened against.
struct DatabaseFile: Equatable, Sendable {
  let path: String
  private let device: dev_t
  private let inode: ino_t

  var directory: URL { URL(filePath: path).deletingLastPathComponent() }

  init(at entry: String) throws {
    var info = stat()
    guard lstat(entry, &info) == 0 else {
      throw StorageError.fileFailure(errno, at: entry)
    }
    let kind = info.st_mode & S_IFMT
    guard kind == S_IFREG || kind == S_IFLNK else { throw StorageError.invalidDatabaseTarget }
    guard let resolved = realpath(entry, nil) else {
      let code = errno
      if kind == S_IFLNK, code == ENOENT || code == ELOOP || code == ENOTDIR {
        throw StorageError.invalidDatabaseTarget
      }
      throw StorageError.fileFailure(code, at: entry)
    }
    defer { free(resolved) }
    let path = String(cString: resolved)
    guard lstat(path, &info) == 0 else {
      throw StorageError.fileFailure(errno, at: path)
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw StorageError.invalidDatabaseTarget }
    self.path = path
    device = info.st_dev
    inode = info.st_ino
  }

  static func isMissing(_ entry: String) -> Bool {
    var info = stat()
    return lstat(entry, &info) != 0 && errno == ENOENT
  }

  func requireCurrent(at entry: String) throws {
    do {
      guard try DatabaseFile(at: entry) == self else { throw StorageError.databaseReplaced }
    } catch let error as StorageError where error == .cannotOpen || error == .invalidDatabaseTarget
    {
      throw StorageError.databaseReplaced
    }
  }
}
