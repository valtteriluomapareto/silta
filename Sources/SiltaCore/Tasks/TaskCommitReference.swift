import Foundation
import GRDB

/// An immutable whole-tree code link. The literal dot keeps the persisted grammar portable.
struct TaskCommitReference: Hashable, Sendable {
  let app: String
  let sha: String

  init?(_ ref: String, requireRootPath: Bool = false) {
    guard ref.hasPrefix("code:") else { return nil }
    let root = ref.hasSuffix(":.")
    guard root || !requireRootPath else { return nil }
    let owner = ref.dropFirst(5).dropLast(root ? 2 : 0)
      .split(separator: "@", omittingEmptySubsequences: false)
    guard owner.count == 2, WorkspaceConfig.isValidIdentifier(String(owner[0])),
      Self.isFullSHA(owner[1])
    else { return nil }
    app = String(owner[0])
    sha = owner[1].lowercased()
  }

  var stored: String { app + "@" + sha + ":." }

  static func isFullSHA(_ value: some StringProtocol) -> Bool {
    let bytes = value.utf8
    return [40, 64].contains(bytes.count)
      && bytes.allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }
  }

  static func appNames(_ app: WorkspaceSlugs.Resolved, in db: Database) throws -> Set<String> {
    let previous = try String.fetchOne(
      db, sql: "SELECT previous_slugs FROM app WHERE id=?", arguments: [app.id])
    return Set(try WorkspaceSlugs.previous(previous) + [app.slug])
  }

  static func matchingTaskIDs(_ ref: String, workspace: Int64, in db: Database) throws
    -> Set<Int64>
  {
    if ref.hasPrefix("url:"), let url = try TaskLinkTarget.url(ref).external {
      return Set(
        try Int64.fetchAll(
          db,
          sql: """
            SELECT from_id FROM link WHERE workspace_id=? AND from_kind='task' AND to_kind='url'
              AND CAST(to_ext AS BLOB)=?
            """, arguments: [workspace, Data(url.utf8)]))
    }
    guard let commit = Self(ref) else {
      throw TaskError.invalid("Use --link url:<http(s) URL> or code:<app>@<full commit SHA>.")
    }
    let app = try TaskService.namedSlug(.app, commit.app, workspace: workspace, in: db)
    let names = try appNames(app, in: db)
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT from_id,to_ext FROM link
        WHERE workspace_id=? AND from_kind='task' AND to_kind='code'
          AND anchor IS NULL AND substr(to_ext,-2)=':.'
        """, arguments: [workspace])
    return Set(
      rows.compactMap { row in
        guard let saved = Self("code:" + (row["to_ext"] as String), requireRootPath: true),
          saved.sha == commit.sha, names.contains(saved.app)
        else { return nil }
        return row["from_id"] as Int64
      })
  }
}
