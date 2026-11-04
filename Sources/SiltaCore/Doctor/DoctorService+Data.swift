import Foundation
import GRDB

extension DoctorService {
  static func data(_ db: Database, at now: Date) throws -> [DoctorCheck] {
    let repos = try Row.fetchAll(
      db,
      sql: """
        SELECT w.slug AS workspace, r.slug, p.path, p.fetched_at FROM repo r
        JOIN workspace w ON w.id=r.workspace_id LEFT JOIN repo_path p ON p.repo_id=r.id
        ORDER BY w.slug,r.slug
        """)
    let dead = repos.filter { row in
      guard let path: String = row["path"] else { return true }
      return !hasGitMarker(path)
    }
    let stale = repos.filter { row in isOld(row["fetched_at"], at: now, seconds: 86400) }
    let overrides = try Row.fetchAll(db, sql: "SELECT path FROM worktree_override ORDER BY path")
    let orphaned = overrides.filter { !hasGitMarker($0["path"]) }
    return [
      DoctorCheck(
        id: "git.repos", status: dead.isEmpty ? "pass" : "fail",
        message: dead.isEmpty
          ? "All registered repository paths have a .git marker."
          : "\(dead.count) registered repository path(s) are missing a .git marker.",
        next: repoNext(dead, fetch: false)),
      DoctorCheck(
        id: "git.fetch", status: stale.isEmpty ? "pass" : "warning",
        message: stale.isEmpty
          ? "No stale repository fetches."
          : "\(stale.count) repository fetch timestamp(s) are missing, invalid or older than 24 hours.",
        next: repoNext(stale, fetch: true)),
      DoctorCheck(
        id: "git.overrides", status: orphaned.isEmpty ? "pass" : "warning",
        message: orphaned.isEmpty
          ? "No orphaned worktree overrides."
          : "\(orphaned.count) worktree override(s) have no .git marker; repairs need human follow-up.",
        next: orphaned.map { row in
          let path: String = row["path"]
          return "/bin/ls -ld " + shellWord(path) + " "
            + shellWord(URL(filePath: path).appending(path: ".git").path)
        }),
    ]
  }

  private static func repoNext(_ rows: [Row], fetch: Bool) -> [String] {
    var next: [String] = []
    for row in rows {
      let workspace: String = row["workspace"]
      let slug: String = row["slug"]
      if !fetch, let path: String = row["path"] {
        next.append(
          "/bin/ls -ld " + shellWord(path) + " "
            + shellWord(URL(filePath: path).appending(path: ".git").path))
      }
      let command =
        "silta --ws " + shellWord(workspace)
        + (fetch ? " repo fetch " + shellWord(slug) : " ws show")
      if !next.contains(command) { next.append(command) }
    }
    return next
  }

  static func claims(_ db: Database, at now: Date) throws -> DoctorCheck {
    let claims = try Row.fetchAll(
      db,
      sql: """
        SELECT w.slug AS workspace,w.task_prefix,t.seq,t.claimed_at FROM task t
        JOIN workspace w ON w.id=t.workspace_id WHERE t.claimed_by IS NOT NULL ORDER BY w.slug,t.seq
        """
    ).filter { isOld($0["claimed_at"], at: now, seconds: 7200) }
    return DoctorCheck(
      id: "data.claims", status: claims.isEmpty ? "pass" : "warning",
      message: claims.isEmpty
        ? "No claims older than 2 hours."
        : "\(claims.count) claim timestamp(s) are missing, invalid or older than 2 hours; ownership is unchanged.",
      next: claims.map { row in
        let workspace: String = row["workspace"]
        let prefix: String = row["task_prefix"]
        let seq: Int = row["seq"]
        return "silta --ws " + shellWord(workspace) + " task show "
          + shellWord("\(prefix)-\(seq)")
      })
  }

  private static func hasGitMarker(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: URL(filePath: path).appending(path: ".git").path)
  }

  private static func isOld(_ raw: String?, at now: Date, seconds: TimeInterval) -> Bool {
    guard let raw else { return true }
    let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    do {
      let date = try format.parse(raw)
      return date.formatted(format) != raw || now.timeIntervalSince(date) > seconds
    } catch { return true }
  }

}
