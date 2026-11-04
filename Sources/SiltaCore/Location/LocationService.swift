package import Foundation
import GRDB

/// Resolves a path from registered repositories and live git/task evidence, without fetching.
package struct LocationService {
  let environment: SiltaEnvironment

  /// Uses injected command dependencies; construction does no I/O.
  package init(environment: SiltaEnvironment) {
    self.environment = environment
  }

  /// Reports low confidence rather than guessing. Reads only truth storage; distance
  /// results may be cached opportunistically in index.db.
  package func resolve(
    path: URL, workspace: String? = nil, app: String? = nil, task: String? = nil,
    ignoringOverride: Bool = false
  ) async throws -> LocationResult {
    let context = try await inspect(path: path, workspace: workspace)
    let repo = context.repo
    let git = context.git
    let candidates = context.candidates
    let branch = try await git.value(
      ["symbolic-ref", "--quiet", "--short", "HEAD"], optional: true)
    let head = try await git.required(["rev-parse", "--verify", "HEAD"])
    var result = LocationResult(
      workspace: repo.workspace, repo: repo.slug, branch: branch,
      head: head, confidence: "low", reason: "unresolved", candidates: candidates)
    func picked(_ app: String, _ reason: String) -> LocationResult {
      var selected = result
      selected.app = app
      selected.confidence = "high"
      selected.reason = reason
      return selected
    }
    if let app {
      try validate(app, candidates: candidates, repo: repo, path: context.path)
      return picked(app, "explicit")
    }
    if candidates.count == 1, let single = candidates.first { return picked(single.app, "single") }
    let override = try environment.db.read {
      try Int64.fetchOne(
        $0, sql: "SELECT app_id FROM worktree_override WHERE path=?",
        arguments: [context.path.path])
    }
    if !ignoringOverride, let selected = candidates.first(where: { $0.id == override }) {
      return picked(selected.app, "override")
    }
    if let taskApp = try taskApp(
      task, branch: branch, repo: repo, candidates: candidates, path: context.path)
    {
      return picked(taskApp, "task")
    }
    if let evidence = try await git.evidence(branch: branch, candidates: candidates) {
      result.app = evidence.app
      result.confidence = evidence.app == nil ? "low" : "high"
      result.reason = evidence.reason
      return result
    }
    return try await distance(result, path: context.path, git: git)
  }

  private func taskApp(
    _ task: String?, branch: String?, repo: LocationRepository,
    candidates: [LocationCandidate], path: URL
  ) throws -> String? {
    if let task {
      let selected = try TaskService(environment: environment, workspace: repo.workspace).show(task)
      if let app = selected.app {
        try validate(app, candidates: candidates, repo: repo, path: path)
        return app
      }
      return nil
    }
    return try environment.db.read { db in
      for (column, value) in [("claimed_by", environment.actor.description), ("branch", branch)] {
        guard let value else { continue }
        let ids = try Int64.fetchAll(
          db,
          sql: """
            SELECT DISTINCT task.app_id FROM task JOIN repo ON repo.id=?
            WHERE task.workspace_id=repo.workspace_id AND task.\(column)=?
              AND task.app_id IS NOT NULL AND task.status IN ('todo','doing','review')
            AND task.external_ref IS NULL
            """, arguments: [repo.id, value])
        let matches = candidates.filter { ids.contains($0.id) }
        if matches.count == 1 { return matches.first?.app }
      }
      return nil
    }
  }

  func validate(_ app: String, candidates: [LocationCandidate], repo: LocationRepository, path: URL)
    throws
  {
    guard repo.apps.contains(where: { $0.app == app }) else {
      throw LocationError.app(app, workspace: repo.workspace)
    }
    guard candidates.contains(where: { $0.app == app }) else {
      throw LocationError.outsideCandidates(
        candidates.map(\.app), workspace: repo.workspace, path: path.path)
    }
  }

  func inspect(path: URL, workspace: String?) async throws
    -> LocationContext
  {
    let path = try LocationPath.canonical(path)
    guard try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw LocationError.invalidPath
    }
    let git = LocationGit(runner: environment.git, directory: path)
    guard let common = try await git.commonDirectory() else { throw LocationError.unregistered }
    if let workspace { _ = try WorkspaceSelection.resolve(workspace, in: environment.db) }
    for repo in try LocationRepository.all(workspace: workspace, in: environment.db) {
      guard FileManager.default.fileExists(atPath: repo.path) else { continue }
      let registered = LocationGit(runner: environment.git, directory: URL(filePath: repo.path))
      guard try await registered.commonDirectory() == common else { continue }
      let root = try LocationPath.canonical(
        URL(
          filePath:
            try await git.required(["rev-parse", "--show-toplevel"])))
      return LocationContext(
        path: path, repo: repo, git: git,
        candidates: try repo.candidates(at: path, root: root))
    }
    throw LocationError.unregistered
  }
}
