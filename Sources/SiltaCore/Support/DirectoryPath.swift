import Darwin
import Foundation

/// Opens directories from a canonical absolute path without following any component's links.
enum DirectoryPath {
  /// Resolve the caller's configured root before inspecting any managed child.
  static func canonicalHome(_ home: URL) -> URL {
    (try? canonicalURL(home)) ?? home  // let the directory open report the actual filesystem error
  }

  static func open(_ directory: URL, creating: Bool = false) throws -> Int32 {
    guard directory.path.hasPrefix("/") else { throw POSIXError(.EINVAL) }
    var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { throw failure() }
    do {
      for component in directory.path.split(separator: "/") {
        let child = try open(String(component), in: parent, creating: creating)
        close(parent)
        parent = child
      }
      return parent
    } catch {
      close(parent)
      throw error
    }
  }

  static func open(_ name: String, in parent: Int32, creating: Bool = false) throws -> Int32 {
    guard name != ".", name != "..", !name.contains("/") else { throw POSIXError(.EINVAL) }
    let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    var child = openat(parent, name, flags)
    if child < 0, errno == ENOENT, creating {
      guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw failure() }
      child = openat(parent, name, flags)
    }
    guard child >= 0 else { throw failure() }
    return child
  }

  /// Reserves a private staging directory without traversing the parent by name.
  static func makeTemporary(in parent: Int32, prefix: String) throws -> String {
    for _ in 0..<32 {
      let token = UUID().uuidString.prefix(6)  // guard:allow-nondeterminism staging name
      let name = prefix + token
      if mkdirat(parent, name, 0o700) == 0 { return name }
      guard errno == EEXIST else { throw failure() }
    }
    throw POSIXError(.EEXIST)
  }

  /// Lists the opened directory, even if its pathname has changed.
  static func names(in directory: Int32) throws -> [String] {
    let cursor = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard cursor >= 0 else { throw failure() }
    guard let stream = fdopendir(cursor) else {
      let error = failure()
      close(cursor)
      throw error
    }
    defer { closedir(stream) }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw failure() }
        return names
      }
      let name =
        withUnsafeBytes(of: entry.pointee.d_name) {
          String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
        } ?? "\u{FFFD}"
      if name != ".", name != ".." { names.append(name) }
    }
  }

  static func failure() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
