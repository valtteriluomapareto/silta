import Foundation

/// A read against the selected app's committed tree, never its working directory.
package enum CodeRead: Sendable {
  /// Reads a literal file, optionally selecting positive inclusive lines.
  case show(String, lines: String?)
  /// Searches committed text for an extended regular expression, optionally limited by one
  /// ordinary relative wildcard pathspec.
  case grep(String, pathspec: String?)
  /// Lists commit SHA and subject, optionally for a literal path.
  case log(String?, count: Int)
  /// Lists immediate names in a literal directory.
  case list(String?)

  /// `show` without `--lines` prints at most this many lines (spec §10).
  static let showLimit = 400
  /// `grep` prints at most this many matching lines (spec §10).
  static let grepLimit = 200
  static let byteLimit = 1024 * 1024

  func contentCapture() throws -> GitCapture {
    guard case .show(_, let lines) = self else { return .init(byteLimit: Self.byteLimit) }
    return try .init(
      byteLimit: Self.byteLimit, skipLines: (lineRange(lines)?.lowerBound ?? 1) - 1)
  }

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
      guard isGitRelativePath(value) else {
        throw CodeError.invalid("Use an app-relative path without .. components.", command: command)
      }
    }
    switch self {
    case .show(_, let lines): _ = try lineRange(lines)
    case .log(_, let count):
      guard count > 0 else { throw CodeError.invalid("-n must be positive.", command: command) }
    case .grep(let pattern, _):
      guard !Self.normalized(path).hasPrefix(":") else {
        throw CodeError.invalid(
          "Git pathspec magic (a leading :) is unsupported.", command: command)
      }
      guard !pattern.contains("\0") else {
        throw CodeError.invalid("Pattern contains NUL.", command: command)
      }
    case .list: break
    }
  }

  func lineRange(_ lines: String?) throws -> ClosedRange<Int>? {
    guard let lines else { return nil }
    let bounds = lines.split(separator: "-", omittingEmptySubsequences: false).compactMap {
      Int($0)
    }
    guard bounds.count <= 2, bounds.map(String.init).joined(separator: "-") == lines,
      let start = bounds.first, let end = bounds.last, start > 0, end >= start
    else {
      throw CodeError.invalid(
        "--lines must be a positive line N or inclusive range A-B.", command: "silta code show")
    }
    return start...end
  }

  /// The git arguments for this read at `sha`. Attributes come from `sha` too, so the
  /// clone's working tree can't change the result.
  func arguments(sha: String, subpath: String) -> [String] {
    let path = Self.normalized(subpath + "/" + self.path)
    let read: [String]
    switch self {
    case .show:
      read = [
        "show", "--format=", "--no-color", "--no-ext-diff", "--no-textconv", sha + ":" + path,
      ]
    case .grep(let pattern, _):
      read =
        [
          "grep", "-I", "-z", "--no-textconv", "--no-color", "--no-column", "--no-heading",
          "--no-break", "--extended-regexp", "-n", "-e", pattern, sha, "--",
        ] + Self.pathspecs(subpath: Self.normalized(subpath), user: Self.normalized(self.path))
    case .log(_, let count):
      read =
        [
          "--literal-pathspecs", "log", "--no-color", "--no-decorate", "--no-ext-diff",
          "--no-textconv", "--no-show-signature", "--no-notes", "--no-patch", "--format=%H %s",
          "-n", String(count), sha, "--",
        ] + (path.isEmpty ? [] : [path])
    case .list: read = ["ls-tree", "-z", sha + ":" + path]
    }
    return ["--attr-source=" + sha] + read
  }

  /// Repeats this read for `target` as a shell-quoted command.
  ///
  /// A literal path may begin with `-`, and an option after `--` would be read as a
  /// path, so options come first and every path follows a `--` separator.
  package func command(workspace: String, target: String, prod: Bool) -> String {
    var words = ["silta", "--ws", shellWord(workspace), "code", verb, shellWord(target)]
    if prod { words.append("--prod") }
    switch self {
    case .show(let path, let lines):
      if let lines { words += ["--lines", lines] }
      words += ["--", shellWord(path)]
    case .grep(let pattern, let pathspec):
      words += ["--", shellWord(pattern)] + (pathspec.map { [shellWord($0)] } ?? [])
    case .log(let path, let count):
      words += ["-n", String(count)] + (path.map { ["--", shellWord($0)] } ?? [])
    case .list(let path):
      words += path.map { ["--", shellWord($0)] } ?? []
    }
    return words.joined(separator: " ")
  }

  static func normalized(_ path: String) -> String {
    path.utf8.split(separator: 47)
      .filter { !$0.elementsEqual([46]) }
      .map { Self.text($0) }.joined(separator: "/")
  }

  /// Decodes committed bytes as UTF-8, replacing invalid sequences with U+FFFD, so a
  /// file in another encoding still reads (spec §10).
  static func text(_ bytes: some Collection<UInt8>) -> String {
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: bytes, as: UTF8.self)
  }

  /// Escapes the configured subpath so its wildcard characters, and a leading `:` that
  /// would start pathspec magic, match only themselves. An escaped pathspec matches as a
  /// wildcard, not as a directory prefix, so a directory also needs its own `/*`.
  private static func pathspecs(subpath: String, user: String) -> [String] {
    guard !subpath.isEmpty else { return [user.isEmpty ? "." : user] }
    let literal =
      (subpath.hasPrefix(":") ? "\\" : "")
      + subpath.map { "*?[\\".contains($0) ? "\\" + String($0) : String($0) }.joined()
    return user.isEmpty
      ? [literal + "/*"] : [literal + "/" + user, literal + "/" + user + "/*"]
  }

  private static func shownPath(_ path: String) -> String {
    let escaped = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\"\\"))
    return path.rangeOfCharacter(from: escaped) == nil ? path : path.debugDescription
  }

  private func grepOutput(
    _ result: GitResult, sha: String, subpath: String, _ unreadable: CodeError
  ) throws -> (output: String, warnings: [OutputWarning]) {
    let bytes = result.stdout
    let prefix = sha + ":" + (subpath.isEmpty ? "" : subpath + "/")
    var offset = 0
    var output = ""
    var matches = 0
    while offset < bytes.count {
      guard let pathEnd = bytes[offset...].firstIndex(of: 0),
        let numberEnd = bytes[(pathEnd + 1)...].firstIndex(of: 0)
      else {
        if result.stdoutTruncated { break }
        throw unreadable
      }
      let lineEnd = bytes[(numberEnd + 1)...].firstIndex(of: 10) ?? bytes.count
      if result.stdoutTruncated, lineEnd == bytes.count { break }
      let path = CodeRead.text(bytes[offset..<pathEnd])
      guard path.hasPrefix(prefix) else { throw unreadable }
      matches += 1
      if matches <= Self.grepLimit {
        output +=
          Self.shownPath(String(path.dropFirst(prefix.count))) + ":"
          + CodeRead.text(bytes[(pathEnd + 1)..<numberEnd]) + ":"
          + CodeRead.text(bytes[(numberEnd + 1)..<lineEnd])
          + (lineEnd < bytes.count ? "\n" : "")
      }
      offset = lineEnd + 1
    }
    if result.stdoutTruncated { return (output, [byteWarning]) }
    guard matches > Self.grepLimit else { return (output, []) }
    return (
      output,
      [
        .init(
          code: "output_truncated",
          message:
            "Output cut after \(Self.grepLimit) of \(matches) matching lines; "
            + "narrow it with a pathspec or a narrower pattern.")
      ]
    )
  }
}

extension CodeRead {
  /// Formats complete records, distinguishing a capture limit from real EOF.
  func formatted(_ result: GitResult, sha: String, subpath: String, unreadable: CodeError) throws
    -> (output: String, warnings: [OutputWarning])
  {
    switch self {
    case .grep:
      return try grepOutput(result, sha: sha, subpath: Self.normalized(subpath), unreadable)
    case .list:
      let entries = Self.completeRecords(result, delimiter: 0).split(separator: "\0")
      let output = entries.map { entry in
        let fields = entry.split(separator: "\t", maxSplits: 1)
        let tree = fields.first?.split(separator: " ").dropFirst().first == "tree"
        return Self.shownPath(String(fields.last ?? "") + (tree ? "/" : "")) + "\n"
      }
      return (output.joined(), result.stdoutTruncated ? [byteWarning] : [])
    case .log:
      return (
        Self.completeRecords(result, delimiter: 10),
        result.stdoutTruncated ? [byteWarning] : []
      )
    case .show:
      return try showOutput(result)
    }
  }

  private func showOutput(_ result: GitResult) throws -> (String, [OutputWarning]) {
    guard case .show(let path, let selection) = self else { return ("", []) }
    let text = Self.completeRecords(result, delimiter: 10)
    let lines = text.components(separatedBy: "\n")
    let count = text.isEmpty ? 0 : text.utf8.last == 10 ? lines.count - 1 : lines.count
    let end = result.stdoutSkippedLines + count
    if let range = try lineRange(selection) {
      let warnings: [OutputWarning]
      if range.upperBound <= end {
        warnings = []
      } else if result.stdoutTruncated {
        warnings = [byteWarning]
      } else {
        warnings = [
          .init(
            code: "lines_past_eof",
            message:
              "\(path.debugDescription) has \(end) line\(end == 1 ? "" : "s"); "
              + "--lines \(selection ?? "") goes past the end.")
        ]
      }
      let output = lines.prefix(count).enumerated().filter {
        range.contains(result.stdoutSkippedLines + $0.offset + 1)
      }.map { $0.element + ($0.offset < lines.count - 1 ? "\n" : "") }
      return (output.joined(), warnings)
    }
    let output =
      count > Self.showLimit ? lines.prefix(Self.showLimit).joined(separator: "\n") + "\n" : text
    if result.stdoutTruncated { return (output, [byteWarning]) }
    guard count > Self.showLimit else { return (output, []) }
    let warning = OutputWarning(
      code: "output_truncated",
      message:
        "Output cut after \(Self.showLimit) of \(count) lines; "
        + "read the rest with --lines \(Self.showLimit + 1)-\(count).")
    return (output, [warning])
  }

  private static func completeRecords(_ result: GitResult, delimiter: UInt8) -> String {
    guard result.stdoutTruncated else { return text(result.stdout) }
    guard let last = result.stdout.lastIndex(of: delimiter) else { return "" }
    return text(result.stdout[...last])
  }

  private var byteWarning: OutputWarning {
    let hint: String
    switch self {
    case .show: hint = "Choose a smaller or later range with --lines A-B."
    case .grep: hint = "Narrow it with a pathspec or a narrower pattern."
    case .log: hint = "Use a smaller -n or specify a path."
    case .list: hint = "Specify a subdirectory."
    }
    return .init(code: "output_truncated", message: "Git output exceeded 1 MiB. " + hint)
  }
}
