import Darwin
import Foundation
import SiltaCore

/// The shared process deadline is armed before this gateway can read stdin.
enum AgentHook {
  static func environment(_ snapshot: [String: String]) throws -> [String: String] {
    let input = try JSONDecoder().decode(AgentHookInput.self, from: readInput())
    guard ActorID.parse("agent:claude:" + input.sessionID) != nil,
      let file = snapshot["CLAUDE_ENV_FILE"], !file.isEmpty
    else { throw SeamError.invalidSession }
    try export(input.sessionID, file: file, snapshot: snapshot)
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
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_size <= 1_048_576
    else { throw SeamError.invalidSession }
    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(
      contentsOf: Data("\nexport SILTA_SESSION='\(session)'\n".utf8))
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
