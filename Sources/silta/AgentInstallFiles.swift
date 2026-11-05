import Darwin
import Foundation
import SiltaCore

/// Relative descriptor traversal never follows a harness-directory symlink.
final class AgentInstallFiles {
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
    for component in path.split(separator: "/").dropLast() {
      let name = String(component)
      var child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      if child < 0, errno == ENOENT, create {
        guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else {
          Darwin.close(fd)
          throw refusal(path, "cannot create parent directory")
        }
        child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      }
      let missing = child < 0 && errno == ENOENT
      Darwin.close(fd)
      if child < 0 {
        if missing && !create { return nil }
        throw refusal(path, "unsafe or inaccessible parent directory")
      }
      fd = child
    }
    return fd
  }

  func read(_ path: String) throws -> (Data?, UInt16) {
    guard let parent = try directory(path, create: false) else { return (nil, 0o600) }
    defer { Darwin.close(parent) }
    let fd = openat(
      parent, URL(filePath: path).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0, errno == ENOENT { return (nil, 0o600) }
    guard fd >= 0 else { throw refusal(path, "cannot safely open file") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_size <= 1_048_576
    else { throw refusal(path, "expected one regular file of at most 1 MiB") }
    let data = try handle.readToEnd() ?? Data()
    guard String(data: data, encoding: .utf8) != nil else { throw refusal(path, "invalid UTF-8") }
    return (data, info.st_mode & 0o777)
  }

  func apply(_ edits: [AgentInstallPlan.Edit]) throws {
    var completed: [String] = []
    do {
      for edit in edits {
        let (data, mode) = try read(edit.path)
        guard data == edit.before, mode == edit.mode else {
          throw refusal(edit.path, "changed since preview")
        }
      }
      for edit in edits {
        try replace(edit)
        completed.append(edit.path)
      }
    } catch {
      let detail = (error as? any CodedError)?.message ?? "I/O failed for a selected target"
      throw AgentInstallError(
        .env,
        "Harness write failed: \(detail) Completed: "
          + (completed.isEmpty ? "none" : completed.joined(separator: ", "))
          + ". Check the named path's permissions/structure; no rollback. Review a fresh preview.",
        next: [preview + " --help", preview], human: true)
    }
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
      guard fchmod(fd, edit.mode) == 0, fsync(fd) == 0,
        renameat(parent, temporary, parent, name) == 0
      else { throw refusal(edit.path, "cannot commit replacement") }
    } else if unlinkat(parent, name, 0) != 0 {
      throw refusal(edit.path, "cannot remove owned file")
    }
  }
}
