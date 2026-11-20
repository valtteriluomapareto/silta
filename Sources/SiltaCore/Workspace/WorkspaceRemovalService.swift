import Darwin
import Foundation
import GRDB

/// A workspace removal preview or its committed backup receipt.
package struct WorkspaceRemovalReport: Encodable, Sendable {
  package struct Count: Encodable, Sendable {
    package let kind: String
    package let count: Int
  }

  package let workspace: String
  package let name: String
  package let dryRun: Bool
  package let counts: [Count]
  package let savedDefault: Bool
  package let registeredClones: [String]
  package var backup: String?
  package var recovery: String?
  package var next: [String]?
  package var nextBy: String?

  private enum CodingKeys: String, CodingKey {
    case workspace, name, counts, backup, recovery, next
    case dryRun = "dry_run"
    case savedDefault = "saved_default"
    case registeredClones = "registered_clones"
    case nextBy = "next_by"
  }
}

/// Removes a nominated workspace and its owned rows, with a fresh recovery copy.
package struct WorkspaceRemovalService {
  let environment: SiltaEnvironment

  package init(environment: SiltaEnvironment) { self.environment = environment }

  package func remove(_ slug: String, dryRun: Bool, allowActive: Bool) async throws
    -> WorkspaceRemovalReport
  {
    if !dryRun && !environment.actor.isHuman {
      throw WorkspaceRemovalError.directHuman(slug, allowActive: allowActive)
    }
    let store = environment.db
    guard FileManager.default.fileExists(atPath: store.path) else {
      throw WorkspaceError.unknown(slug)
    }
    let selected = try store.read { try capture(slug, in: $0) }
    let clones = try await liveClones(selected.paths, workspace: slug)
    if dryRun {
      return try store.read { db in
        try check(selected, slug: slug, in: db)
        return try report(slug, selection: selected, clones: clones, dryRun: true, in: db)
      }
    }
    return try store.write(keepingBackup: \.backup) { tx in
      try check(selected, slug: slug, in: tx.database)
      var report = try self.report(
        slug, selection: selected, clones: clones, dryRun: false, in: tx.database)
      guard allowActive || (!report.savedDefault && clones.isEmpty) else {
        throw WorkspaceRemovalError.active(slug)
      }
      let files = try WorkspaceRemovalBackup.make(
        slug, tx: tx, home: environment.home.url, date: environment.clock.now())
      try WorkspaceOwnedRows.removeWorkspace(selected.id, in: tx)
      report.backup = files.backup
      report.recovery = files.recovery
      report.next =
        RestoreService.canNameInRecovery(files.recovery) && RestoreService.canNameInRecovery(slug)
        ? [
          workspaceCommand(
            "silta restore " + shellWord(files.recovery) + " --dry-run", workspace: slug)
        ]
        : ["silta guide human"]
      report.nextBy = NextBy.agent.rawValue
      return report
    }
  }

  private struct Selection {
    let id: Int64
    let uid: String
    let name: String
    let paths: [String]

    func matches(_ other: Selection) -> Bool {
      id == other.id && uid.utf8.elementsEqual(other.uid.utf8)
        && name.utf8.elementsEqual(other.name.utf8) && paths.count == other.paths.count
        && zip(paths, other.paths).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
  }

  private func capture(_ slug: String, in db: Database) throws -> Selection {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT id,uid,CAST(name AS BLOB) AS name_bytes FROM workspace
          WHERE slug=CAST(? AS TEXT)
          """,
        arguments: [Data(slug.utf8)])
    else { throw WorkspaceError.unknown(slug) }
    let id: Int64 = row["id"]
    guard let name = try row.strictText("name_bytes") else { throw StorageError.corrupt }
    let paths = try Row.fetchAll(
      db,
      sql: """
        SELECT CAST(repo_path.path AS BLOB) AS path_bytes FROM repo_path
        JOIN repo ON repo.id=repo_path.repo_id WHERE repo.workspace_id=? ORDER BY repo.id
        """, arguments: [id]
    ).compactMap { try $0.strictText("path_bytes") }
    return Selection(id: id, uid: row["uid"], name: name, paths: paths)
  }

  private func check(_ captured: Selection, slug: String, in db: Database) throws {
    do {
      guard try capture(slug, in: db).matches(captured) else {
        throw WorkspaceRemovalError.changed(slug)
      }
    } catch WorkspaceError.unknown {
      throw WorkspaceRemovalError.changed(slug)
    }
  }

  private func liveClones(_ paths: [String], workspace: String) async throws -> [String] {
    var result: [String] = []
    for path in paths {
      var info = stat()
      if lstat(path, &info) != 0 {
        if errno == ENOENT || errno == ENOTDIR { continue }
        throw WorkspaceRemovalError.registration(workspace)
      }
      let git = LocationGit(runner: environment.git, directory: URL(filePath: path))
      do {
        if try await git.commonDirectory() != nil { result.append(path) }
      } catch {
        throw WorkspaceRemovalError.registration(workspace)
      }
    }
    return result.sorted()
  }

  private func report(
    _ slug: String, selection: Selection, clones: [String], dryRun: Bool, in db: Database
  ) throws -> WorkspaceRemovalReport {
    let isDefault =
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(SELECT 1 FROM meta
            WHERE key='current_workspace' AND value=CAST(? AS TEXT))
          """,
        arguments: [Data(slug.utf8)]) == true
    return WorkspaceRemovalReport(
      workspace: slug, name: HumanText.line(selection.name), dryRun: dryRun,
      counts: try WorkspaceOwnedRows.counts(selection.id, in: db),
      savedDefault: isDefault, registeredClones: clones)
  }
}

enum WorkspaceRemovalError: CodedError {
  case directHuman(String, allowActive: Bool)
  case active(String)
  case changed(String)
  case registration(String)

  var code: ErrorCode {
    switch self {
    case .directHuman: .humanOnly
    case .active, .changed: .conflict
    case .registration: .env
    }
  }

  var message: String {
    switch self {
    case .directHuman:
      "Workspace removal must be run by a human in their terminal. "
        + "Agents may preview with --dry-run."
    case .active:
      "The workspace is the saved default or has a registered clone. "
        + "Preview it before choosing --allow-active."
    case .changed: "The workspace or its registrations changed before removal."
    case .registration:
      "Could not check a registered clone. Workspace removal requires known registrations."
    }
  }

  var nextBy: NextBy {
    if case .directHuman = self { return .human }
    if case .registration = self { return .human }
    return .agent
  }

  var next: [String] {
    let target: String
    let suffix: String
    switch self {
    case .directHuman(let slug, let allow):
      target = slug
      suffix = allow ? " --allow-active" : ""
    case .active(let slug), .changed(let slug):
      target = slug
      suffix = " --dry-run"
    case .registration(let slug):
      return [workspaceEditRead(slug)]
    }
    guard WorkspaceConfig.isValidIdentifier(target), RestoreService.canNameInRecovery(target)
    else { return ["silta ws ls"] }
    return ["silta ws rm " + shellWord(target) + suffix]
  }
}
