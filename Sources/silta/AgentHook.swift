import Darwin
import Foundation
import SiltaCore

/// The shared process deadline is armed before this gateway can read stdin.
enum AgentHook {
  static func environment(_ snapshot: [String: String], stop: Bool = false) throws -> [String:
    String]?
  {
    let data = try readInput()
    let input = try JSONDecoder().decode(AgentHookInput.self, from: data)
    guard ActorID.parse("agent:claude:" + input.sessionID) != nil else {
      throw SeamError.invalidSession
    }
    if stop, try JSONDecoder().decode(AgentStopInput.self, from: data).active == true { return nil }
    if !stop {
      guard let file = snapshot["CLAUDE_ENV_FILE"], !file.isEmpty else {
        throw SeamError.invalidSession
      }
      try export(input.sessionID, file: file, snapshot: snapshot)
    }
    var environment = snapshot
    environment["SILTA_SESSION"] = input.sessionID
    environment["CLAUDECODE"] = "1"
    return environment
  }

  private static func readInput() throws -> Data {
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
      input.append(chunk)
      guard input.count <= 65_536 else { throw TaskError.input }
    }
    return input
  }

  private static func export(_ session: String, file: String, snapshot: [String: String]) throws {
    let (parent, name) = try parent(file, snapshot: snapshot)
    defer { close(parent) }
    let fd = openat(parent, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard fd >= 0 else { throw SeamError.invalidSession }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SeamError.invalidSession }
    let line = Data("\nexport SILTA_SESSION='\(session)'\n".utf8)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_size + Int64(line.count) <= 1_048_576
    else { throw SeamError.invalidSession }
    try append(line, to: fd)
  }

  private static func append(_ line: Data, to fd: Int32) throws {
    // File-size limits must account for the existing prefix before an append.
    guard lseek(fd, 0, SEEK_END) >= 0 else { throw SeamError.invalidSession }
    let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    if written == line.count { return }
    if written > 0 {
      let end = lseek(fd, 0, SEEK_CUR)
      let flags = fcntl(fd, F_GETFL)
      guard end >= Int64(written), flags >= 0,
        fcntl(fd, F_SETFL, flags & ~O_APPEND) == 0
      else { throw SeamError.invalidSession }
      // Neutralize only our partial append; never truncate another hook's later data.
      let blank = Data(repeating: 10, count: written)
      let restored = blank.withUnsafeBytes {
        pwrite(fd, $0.baseAddress, $0.count, end - Int64(written))
      }
      guard restored == written else { throw SeamError.invalidSession }
    }
    throw SeamError.invalidSession
  }

  private static func parent(_ path: String, snapshot: [String: String]) throws -> (Int32, String) {
    guard path.hasPrefix("/"), let home = snapshot["HOME"], home.hasPrefix("/"),
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { throw SeamError.invalidSession }
    let anchors = try [home, FileManager.default.temporaryDirectory.path, "/tmp"].flatMap {
      [URL(filePath: $0).path, try canonical($0)]
    }.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
      .sorted { $0.count > $1.count }
    guard let anchor = anchors.first(where: { path.hasPrefix($0 + "/") }) else {
      throw SeamError.invalidSession
    }
    let components = path.dropFirst(anchor.count + 1).split(separator: "/").map(String.init)
    guard let name = components.last else { throw SeamError.invalidSession }
    var fd = open(
      try canonical(anchor), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw SeamError.invalidSession }
    do {
      for component in components.dropLast() {
        let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard next >= 0 else { throw SeamError.invalidSession }
        close(fd)
        fd = next
      }
      return (fd, name)
    } catch {
      close(fd)
      throw error
    }
  }

  private static func canonical(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else { throw SeamError.invalidSession }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

private struct AgentHookInput: Decodable {
  let sessionID: String
  enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}

private struct AgentStopInput: Decodable {
  let active: Bool?
  enum CodingKeys: String, CodingKey { case active = "stop_hook_active" }
}
