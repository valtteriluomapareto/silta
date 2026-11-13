import Foundation
import GRDB

/// Concrete storage for an owned identity or an external reference, with an optional line anchor.
struct TaskLinkTarget {
  let kind: String
  var id: Int64?
  var external: String?
  var anchor: String?

  static func resolve(_ raw: String, source: TaskDetails, workspace: String, in db: Database)
    throws -> Self
  {
    if raw.hasPrefix("plan#") || raw.hasPrefix("plan@") && !raw.contains(":") {
      return try plan(raw, source: source, in: db)
    }
    if raw.hasPrefix("diff:") {
      throw TaskError.invalid(
        "Diff references need a review subject; CLI review subjects are unavailable.")
    }
    if raw.hasPrefix("ext:") { throw TaskError.invalid("External parties belong to task block.") }
    if raw.hasPrefix("doc:") {
      return try doc(String(raw.dropFirst(4)), workspace: source.workspaceID, in: db)
    }
    let prefix = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    if ["edge", "service"].contains(prefix) {
      return try map(raw, workspace: source.workspaceID, in: db)
    }
    for kind in ["app", "topic"] where raw.hasPrefix(kind + ":") {
      return Self(
        kind: kind,
        id: try TaskService.entity(
          kind,
          slug: String(raw.dropFirst(kind.count + 1)), workspace: source.workspaceID, in: db))
    }
    if raw.hasPrefix("note:"), raw.count > 5 {
      return Self(kind: "note", external: String(raw.dropFirst(5)))
    }
    if raw.hasPrefix("url:") {
      return try url(raw)
    }
    if raw.hasPrefix("code:") || raw.contains(":") && !raw.hasPrefix("task:") {
      return try code(raw, workspace: source.workspaceID, in: db)
    }
    return try task(raw, workspace: workspace, in: db)
  }

  static func url(_ raw: String) throws -> Self {
    let value = String(raw.dropFirst(4))
    guard let url = URLComponents(string: value), ["https", "http"].contains(url.scheme),
      let host = url.host, !host.isEmpty, url.user == nil
    else {
      throw TaskError.invalid("Use a url:http(s) reference with a host and no credentials.")
    }
    return Self(kind: "url", external: value)
  }

  private static func task(_ raw: String, workspace: String, in db: Database) throws -> Self {
    let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { throw TaskError.invalid("Invalid task comment reference.") }
    let task = try TaskService.lookup(String(parts[0]), workspace: workspace, in: db)
    if parts.count == 1 { return Self(kind: "task", id: task.id) }
    let seq = try number(String(parts[1]))
    guard
      let id = try Int64.fetchOne(
        db,
        sql: """
          SELECT id FROM comment
          WHERE task_id=? AND seq=? AND deleted_at IS NULL
          """, arguments: [task.id, seq])
    else { throw TaskError.notFound("comment " + raw) }
    return Self(kind: "comment", id: id)
  }

  private static func doc(_ raw: String, workspace: Int64, in db: Database) throws -> Self {
    let pieces = raw.split(separator: "/", omittingEmptySubsequences: false)
    let revision = pieces[0].split(separator: "@", omittingEmptySubsequences: false)
    guard pieces.count <= 2, revision.count <= 2 else {
      throw TaskError.invalid("Invalid doc reference.")
    }
    let id = try TaskService.entity("doc", slug: String(revision[0]), workspace: workspace, in: db)
    if revision.count == 1 {
      guard pieces.count == 1 else { throw TaskError.invalid("Doc comments require @<revision>.") }
      return Self(kind: "doc", id: id)
    }
    let rev = try number(String(revision[1]))
    guard
      let revisionID = try Int64.fetchOne(
        db, sql: "SELECT id FROM doc_rev WHERE doc_id=? AND rev=?",
        arguments: [id, rev])
    else { throw TaskError.notFound("doc " + pieces[0]) }
    if pieces.count == 1 { return Self(kind: "doc_rev", id: revisionID) }
    let seq = try number(String(pieces[1]))
    guard
      let commentID = try Int64.fetchOne(
        db,
        sql: """
          SELECT id FROM comment
          WHERE doc_rev_id=? AND seq=? AND deleted_at IS NULL
          """, arguments: [revisionID, seq])
    else { throw TaskError.notFound("comment doc:" + raw) }
    return Self(kind: "comment", id: commentID)
  }

  private static func plan(_ raw: String, source: TaskDetails, in db: Database) throws -> Self {
    guard let match = raw.wholeMatch(of: /plan(?:@([^#]+))?#(.+)/)
    else { throw TaskError.invalid("Use plan[@<revision>]#L<first>[-<last>].") }
    let anchor = String(match.2)
    if let rev = match.1 {
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT id,body_md FROM task_plan_rev WHERE task_id=? AND rev=?",
          arguments: [source.id, try number(String(rev))])
      else { throw TaskError.notFound("plan revision \(rev) of \(source.ref)") }
      try lines(anchor, maximum: lineCount(row["body_md"]))
      return Self(kind: "task_plan_rev", id: row["id"], anchor: "#" + anchor)
    }
    try lines(
      anchor, maximum: lineCount(source.plan))
    return Self(kind: "task", id: source.id, anchor: "plan#" + anchor)
  }

  static func code(_ raw: String, workspace: Int64, in db: Database) throws -> Self {
    let value = raw.hasPrefix("code:") ? String(raw.dropFirst(5)) : raw
    guard let colon = value.firstIndex(of: ":") else {
      throw TaskError.invalid("Invalid code reference.")
    }
    let owner = value[..<colon].split(
      separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    if !raw.hasPrefix("code:"), ["doc", "edge", "service"].contains(String(owner[0])) {
      throw CommandFailure(
        error: TaskError.invalid("Use code: for code in apps named doc, edge or service."),
        next: ["silta task link --help"])
    }
    _ = try TaskService.entity("app", slug: String(owner[0]), workspace: workspace, in: db)
    _ = try storedCodeApp(value)
    return Self(kind: "code", external: value)
  }

  /// Checks an already-classified code payload without resolving a historical app.
  static func storedCodeApp(_ value: String) throws -> String {
    guard let colon = value.firstIndex(of: ":") else {
      throw TaskError.invalid("Invalid code reference.")
    }
    let owner = value[..<colon].split(
      separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard !owner[0].isEmpty else { throw TaskError.invalid("Invalid code reference.") }
    if owner.count == 2 && owner[1].isEmpty {
      throw TaskError.invalid("A code branch cannot be empty.")
    }
    let target = value[value.index(after: colon)...].split(
      separator: "#", omittingEmptySubsequences: false)
    guard target.count <= 2, let path = target.first, !path.isEmpty, !path.hasPrefix("/"),
      !path.split(separator: "/").contains(".."), !value.contains("\\"),
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw TaskError.invalid("Use an app-relative code path and optional #L<first>[-<last>].")
    }
    if target.count == 2 { try lines(String(target[1]), maximum: nil) }
    return String(owner[0])
  }

  private static func lineCount(_ text: String) -> Int {
    text.isEmpty ? 0 : text.components(separatedBy: "\n").count
  }

  private static func number(_ raw: String) throws -> Int64 {
    guard let value = Int64(raw), value > 0, String(value) == raw else {
      throw TaskError.invalid("Reference numbers must be canonical positive integers.")
    }
    return value
  }

  private static func lines(_ raw: String, maximum: Int?) throws {
    guard let match = raw.wholeMatch(of: /L([0-9]+)(?:-([0-9]+))?/) else {
      throw TaskError.invalid("Invalid line range.")
    }
    let first = try number(String(match.1))
    let last = try match.2.map { try number(String($0)) } ?? first
    guard first <= last, maximum.map({ last <= $0 }) ?? true else {
      throw TaskError.invalid("Line range is reversed or outside the referenced plan.")
    }
  }
}
