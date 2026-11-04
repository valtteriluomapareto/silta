import Foundation

/// A read against the selected app's committed tree, never its working directory.
package enum CodeRead: Sendable {
  /// Reads a literal file, optionally selecting positive inclusive lines.
  case show(String, lines: String?)
  /// Searches committed text with one ordinary relative wildcard pathspec.
  case grep(String, pathspec: String?)
  /// Lists commit SHA and subject, optionally for a literal path.
  case log(String?, count: Int)
  /// Lists immediate names in a literal directory.
  case list(String?)

  var verb: String {
    switch self {
    case .show: "show"
    case .grep: "grep"
    case .log: "log"
    case .list: "ls"
    }
  }

  var path: String {
    switch self {
    case .show(let path, _): path
    case .grep(_, let path), .log(let path, _), .list(let path): path ?? ""
    }
  }

  func validate(subpath: String = "") throws {
    let command = "silta code \(verb)"
    for value in [path, subpath] {
      guard !value.hasPrefix("/"), !Self.normalized(value).hasPrefix(":"), !value.contains("\0"),
        !value.split(separator: "/").contains("..")
      else {
        throw CodeError.invalid(
          "Use an app-relative path without .. or Git magic.", command: command)
      }
    }
    switch self {
    case .show(_, let lines): _ = try lineRange(lines)
    case .log(_, let count):
      guard count > 0 else { throw CodeError.invalid("-n must be positive.", command: command) }
    case .grep(let pattern, _):
      guard !pattern.contains("\0") else {
        throw CodeError.invalid("Pattern contains NUL.", command: command)
      }
    default: break
    }
  }

  func lineRange(_ lines: String?) throws -> ClosedRange<Int>? {
    guard let lines else { return nil }
    let parts = lines.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]),
      start > 0, end >= start, "\(start)-\(end)" == lines
    else {
      throw CodeError.invalid(
        "--lines must be a positive inclusive range A-B.", command: "silta code show")
    }
    return start...end
  }
  func arguments(sha: String, path: String) -> [String] {
    switch self {
    case .show:
      return [
        "show", "--format=", "--no-color", "--no-ext-diff", "--no-textconv", sha + ":" + path,
      ]
    case .grep(let pattern, _):
      return [
        "grep", "-I", "-z", "--no-textconv", "--no-color", "--no-column", "--no-heading",
        "--no-break",
        "--basic-regexp", "-n", "-e", pattern, sha, "--", path.isEmpty ? "." : path,
      ]
    case .log(_, let count):
      return
        [
          "--literal-pathspecs", "log", "--no-color", "--no-decorate", "--no-ext-diff",
          "--no-textconv", "--no-show-signature", "--no-notes", "--no-patch", "--format=%H %s",
          "-n", String(count), sha, "--",
        ] + (path.isEmpty ? [] : [path])
    case .list: return ["ls-tree", "-z", "--name-only", sha + ":" + path]
    }
  }

  func formatted(_ text: String, sha: String, subpath: String) throws -> String {
    if case .grep = self {
      return try grepOutput(text, sha: sha, subpath: Self.normalized(subpath))
    }
    if case .list = self {
      return text.split(separator: "\0").map { Self.shownPath(String($0)) + "\n" }.joined()
    }
    guard case .show(_, let selection) = self, let range = try lineRange(selection) else {
      return text
    }
    let lines = text.components(separatedBy: "\n")
    let count = text.utf8.last == 10 ? lines.count - 1 : lines.count
    return lines.prefix(count).enumerated().filter { range.contains($0.offset + 1) }.map {
      String($0.element) + ($0.offset < lines.count - 1 ? "\n" : "")
    }.joined()
  }

  static func normalized(_ path: String) -> String {
    path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
  }

  private static func shownPath(_ path: String) -> String {
    let escaped = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\"\\"))
    return path.rangeOfCharacter(from: escaped) == nil ? path : path.debugDescription
  }

  private func grepOutput(_ text: String, sha: String, subpath: String) throws -> String {
    let bytes = Array(text.utf8)
    let prefix = sha + ":" + (subpath.isEmpty ? "" : subpath + "/")
    var offset = 0
    var output = ""
    while offset < bytes.count {
      guard let pathEnd = bytes[offset...].firstIndex(of: 0),
        let numberEnd = bytes[(pathEnd + 1)...].firstIndex(of: 0)
      else { throw SeamError.gitCapture }
      let lineEnd = bytes[(numberEnd + 1)...].firstIndex(of: 10) ?? bytes.count
      guard let path = String(bytes: bytes[offset..<pathEnd], encoding: .utf8),
        path.hasPrefix(prefix),
        let number = String(bytes: bytes[(pathEnd + 1)..<numberEnd], encoding: .utf8),
        let line = String(bytes: bytes[(numberEnd + 1)..<lineEnd], encoding: .utf8)
      else { throw SeamError.gitCapture }
      output +=
        Self.shownPath(String(path.dropFirst(prefix.count))) + ":" + number + ":" + line
        + (lineEnd < bytes.count ? "\n" : "")
      offset = lineEnd + 1
    }
    return output
  }

}
