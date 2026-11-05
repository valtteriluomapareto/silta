import Darwin
import Foundation
import SiltaCore

/// Relative descriptor traversal never follows a harness-directory symlink.
final class AgentInstallFiles {
  struct Snapshot: Equatable {
    let data: Data?
    let mode: UInt16
    let security: String
  }

  let home: String
  let preview: String
  private let root: Int32

  init(preview: String, claude: Bool, codex: Bool) throws {
    self.preview = preview
    let env = ProcessInfo.processInfo.environment
    guard let path = env["HOME"], path.hasPrefix("/"),
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else {
      throw AgentInstallError(
        .env, "Set HOME to an absolute existing directory.", next: [preview + " --help"],
        human: true)
    }
    home = URL(filePath: path).resolvingSymlinksInPath().path
    for (key, suffix) in [("CODEX_HOME", ".codex"), ("CLAUDE_CONFIG_DIR", ".claude")]
    where suffix == ".codex" ? codex : claude {
      if let override = env[key], !override.isEmpty,
        URL(filePath: override).standardized.path
          != URL(filePath: home).appending(path: suffix).path,
        URL(filePath: override).standardized.path
          != URL(filePath: path).appending(path: suffix).path
      {
        throw AgentInstallError(
          .env, "\(key) must match HOME/\(suffix); fix the launcher.", next: [preview + " --help"],
          human: true)
      }
    }
    root = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard root >= 0 else {
      throw AgentInstallError(
        .env, "Cannot open HOME directory.", next: [preview + " --help"], human: true)
    }
    guard flock(root, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(root)
      throw AgentInstallError(
        .conflict, "Another installer holds HOME; retry the preview.", next: [preview])
    }
  }

  func close() { Darwin.close(root) }

  func refusal(_ path: String, _ reason: String) -> AgentInstallError {
    AgentInstallError(
      .conflict, "Refused \(path): \(reason); ask the human to inspect it.",
      next: [preview + " --help"], human: true)
  }

  private func directory(_ path: String, create: Bool) throws -> Int32? {
    var fd = dup(root)
    guard fd >= 0 else { throw refusal(path, "cannot inspect parent directory") }
    var retained = false
    defer { if !retained { Darwin.close(fd) } }
    try AgentInstallSecurity.directory(fd) { throw refusal(path, "inheritable parent ACL") }
    for component in path.split(separator: "/").dropLast() {
      let name = String(component)
      var child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      if child < 0, errno == ENOENT, create {
        guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else {
          throw refusal(path, "cannot create parent directory")
        }
        child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      }
      if child < 0 {
        if errno == ENOENT && !create { return nil }
        throw refusal(path, "unsafe or inaccessible parent directory")
      }
      Darwin.close(fd)
      fd = child
      try AgentInstallSecurity.directory(fd) { throw refusal(path, "inheritable parent ACL") }
    }
    retained = true
    return fd
  }

  func read(_ path: String) throws -> Snapshot {
    guard let parent = try directory(path, create: false) else {
      return .init(data: nil, mode: 0o600, security: "")
    }
    defer { Darwin.close(parent) }
    let fd = openat(
      parent, URL(filePath: path).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0, errno == ENOENT { return .init(data: nil, mode: 0o600, security: "") }
    guard fd >= 0 else { throw refusal(path, "cannot safely open file") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_size <= 1_048_576
    else { throw refusal(path, "expected one regular file of at most 1 MiB") }
    let security = try AgentInstallSecurity.file(fd, parent: parent, info: info) {
      throw refusal(path, "unsupported security metadata")
    }
    let data = try handle.readToEnd() ?? Data()
    guard String(data: data, encoding: .utf8) != nil else { throw refusal(path, "invalid UTF-8") }
    return .init(data: data, mode: info.st_mode & 0o777, security: security)
  }

  func apply(_ edits: [AgentInstallPlan.Edit]) throws {
    var completed: [String] = []
    var active = "selected target"
    do {
      for edit in edits {
        active = edit.path
        let expected = Snapshot(data: edit.before, mode: edit.mode, security: edit.security)
        guard try read(edit.path) == expected else {
          throw refusal(edit.path, "changed since preview")
        }
      }
      for edit in edits {
        active = edit.path
        try replace(edit)
        completed.append(edit.path)
      }
    } catch {
      let detail = (error as? any CodedError)?.message ?? "\(active): \(Self.writeCause(error))."
      throw AgentInstallError(
        .env,
        "Harness write failed: \(detail) Completed: "
          + (completed.isEmpty ? "none" : completed.joined(separator: ", "))
          + ". Check the named path's permissions/structure; no rollback. Review a fresh preview.",
        next: [preview + " --help", preview], human: true)
    }
  }

  private static func writeCause(_ error: any Error) -> String {
    let outer = error as NSError
    let cause = outer.userInfo[NSUnderlyingErrorKey] as? NSError ?? outer
    if cause.domain == NSPOSIXErrorDomain, cause.code == Int(EFBIG) {
      return "file size limit exceeded"
    }
    return "I/O failure (code \(cause.code)); inspect disk/resource limits and permissions"
  }

  private func replace(_ edit: AgentInstallPlan.Edit) throws {
    guard let parent = try directory(edit.path, create: edit.after != nil) else { return }
    defer { Darwin.close(parent) }
    let name = URL(filePath: edit.path).lastPathComponent
    if let data = edit.after {
      let temporary = ".silta-install-" + UUID().uuidString
      let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, edit.mode)
      guard fd >= 0 else { throw refusal(edit.path, "cannot stage replacement") }
      defer {
        Darwin.close(fd)
        unlinkat(parent, temporary, 0)
      }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      try handle.write(contentsOf: data)
      var info = stat()
      guard fstat(fd, &info) == 0 else { throw refusal(edit.path, "cannot inspect replacement") }
      let security = try AgentInstallSecurity.file(fd, parent: parent, info: info) {
        throw refusal(edit.path, "unsupported replacement security metadata")
      }
      guard edit.before == nil || security == edit.security else {
        throw refusal(edit.path, "replacement ownership differs")
      }
      guard fchmod(fd, edit.mode) == 0, fsync(fd) == 0,
        renameat(parent, temporary, parent, name) == 0
      else { throw refusal(edit.path, "cannot commit replacement") }
    } else if unlinkat(parent, name, 0) != 0 {
      throw refusal(edit.path, "cannot remove owned file")
    }
  }
}
