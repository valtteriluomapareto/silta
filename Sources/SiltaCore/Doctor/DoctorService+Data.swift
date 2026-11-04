import Foundation
import GRDB

extension DoctorService {
  static func data(_ db: Database, at now: Date) throws -> [DoctorCheck] {
    let repos = try Row.fetchAll(
      db,
      sql: """
        SELECT w.slug AS workspace,r.slug,p.path,p.fetched_at FROM repo r
        JOIN workspace w ON w.id=r.workspace_id LEFT JOIN repo_path p ON p.repo_id=r.id
        ORDER BY w.slug,r.slug
        """)
    let unbound = repos.filter { ($0["path"] as String?) == nil }
    let bound = repos.filter { ($0["path"] as String?) != nil }
    let dead = bound.filter { !hasGitMarker($0["path"]) }
    let overrides = try Row.fetchAll(db, sql: "SELECT path FROM worktree_override ORDER BY path")
    let orphaned = overrides.filter { !hasGitMarker($0["path"]) }
    return [
      DoctorCheck(
        id: "git.repos", status: dead.isEmpty ? .pass : .fail,
        message: dead.isEmpty
          ? "All bound repository paths have a .git marker."
          : "\(dead.count) bound repository path(s) are missing a .git marker.",
        next: repoNext(dead, fetch: false)),
      DoctorCheck(
        id: "git.bindings", status: unbound.isEmpty ? .pass : .warning,
        message: unbound.isEmpty
          ? "All repositories have a local binding."
          : "\(unbound.count) repository binding(s) are absent; choose local clone directories before scanning.",
        next: unbound.map {
          "silta --ws " + shellWord($0["workspace"]) + " init --scan <directory>"
        }, nextBy: unbound.isEmpty ? .agent : .human),
      fetchCheck(bound, at: now),
      DoctorCheck(
        id: "git.overrides", status: orphaned.isEmpty ? .pass : .warning,
        message: orphaned.isEmpty
          ? "No orphaned worktree overrides."
          : "\(orphaned.count) worktree override(s) have no .git marker; repairs need human follow-up.",
        next: orphaned.map { pathInspection($0["path"]) }),
    ]
  }

  private static func fetchCheck(_ repos: [Row], at now: Date) -> DoctorCheck {
    let missing = repos.filter { age($0["fetched_at"], at: now) == nil }
    let stale = repos.filter { (age($0["fetched_at"], at: now) ?? 0) > 86400 }
    let affected = repos.filter { (age($0["fetched_at"], at: now) ?? .infinity) > 86400 }
    return DoctorCheck(
      id: "git.fetch", status: affected.isEmpty ? .pass : .warning,
      message: affected.isEmpty
        ? "No stale repository fetches."
        : "\(missing.count) missing or invalid fetch timestamp(s); \(stale.count) stale fetch(es) older than 24 hours.",
      next: repoNext(affected, fetch: true))
  }

  private static func pathInspection(_ path: String) -> String {
    "/bin/ls -ld " + shellWord(path) + " "
      + shellWord(URL(filePath: path).appending(path: ".git").path)
  }

  private static func repoNext(_ rows: [Row], fetch: Bool) -> [String] {
    rows.flatMap { row in
      let workspace: String = row["workspace"]
      let slug: String = row["slug"]
      if fetch { return ["silta --ws " + shellWord(workspace) + " repo fetch " + shellWord(slug)] }
      let path: String = row["path"]
      return [pathInspection(path), "silta --ws " + shellWord(workspace) + " ws show"]
    }
  }

  static func claims(_ db: Database, at now: Date) throws -> DoctorCheck {
    let claims = try Row.fetchAll(
      db,
      sql: """
        SELECT w.slug AS workspace,w.task_prefix,t.seq,t.claimed_at FROM task t
        JOIN workspace w ON w.id=t.workspace_id WHERE t.claimed_by IS NOT NULL ORDER BY w.slug,t.seq
        """
    ).filter { (age($0["claimed_at"], at: now) ?? .infinity) >= TaskService.claimDuration }
    return DoctorCheck(
      id: "data.claims", status: claims.isEmpty ? .pass : .warning,
      message: claims.isEmpty
        ? "No claims at least 2 hours old."
        : "\(claims.count) claim timestamp(s) are missing, invalid or at least 2 hours old; ownership is unchanged.",
      next: claims.map { row in
        let workspace: String = row["workspace"]
        let prefix: String = row["task_prefix"]
        let seq: Int = row["seq"]
        return "silta --ws " + shellWord(workspace) + " task show " + shellWord("\(prefix)-\(seq)")
      })
  }

  private static func hasGitMarker(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: URL(filePath: path).appending(path: ".git").path)
  }

  private static func age(_ raw: String?, at now: Date) -> TimeInterval? {
    guard let raw else { return nil }
    let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    do {
      let date = try format.parse(raw)
      return date.formatted(format) == raw ? now.timeIntervalSince(date) : nil
    } catch { return nil }
  }
}
