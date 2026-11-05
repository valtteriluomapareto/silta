package import Foundation
import GRDB

/// Reads the bare `silta` status: workspace, app, inbox count and the caller's claims.
package struct StatusService {
  let environment: SiltaEnvironment

  /// Uses injected command dependencies; construction does no I/O.
  package init(environment: SiltaEnvironment) {
    self.environment = environment
  }

  /// Resolves the workspace from `workspace`, else the registered repository at `path`,
  /// else the current selection, and returns an empty report when none resolves.
  /// A read: never fetches, initializes, migrates or writes `index.db`. Throws
  /// `not_found` for an unknown explicit workspace and location's other failures.
  package func resolve(path: URL, workspace slug: String?) async throws -> StatusReport {
    var report = StatusReport()
    guard FileManager.default.fileExists(atPath: environment.db.path) else {
      if let slug { throw WorkspaceError.unknown(slug) }
      return report
    }
    let workspace: String
    do {
      let location = try await LocationService(environment: environment).resolve(
        path: path, workspace: slug, cacheWrites: false)
      workspace = location.workspace
      report.app = location.app
      report.location = location.app == nil ? "unresolved" : "resolved"
    } catch let error as any CodedError where error.code == .unregistered {
      if case .outsideRepository? = error as? LocationError {} else { report.inRepository = true }
      do {
        workspace = try WorkspaceSelection.resolve(slug, in: environment.db)
      } catch WorkspaceError.notFound {
        return report
      }
    }
    report.workspace = workspace
    let inbox = try TaskService(environment: environment, workspace: workspace).inbox()
    report.inbox = inbox.items.count + inbox.remaining
    report.claimed = try environment.db.read { db in
      try Row.fetchAll(
        db,
        sql: TaskService.query + """
          \nWHERE task.workspace_id=? AND task.claimed_by=? ORDER BY task.seq
          """,
        arguments: [TaskService.workspaceID(workspace, in: db), environment.actor.description]
      ).map {
        let task = TaskDetails(row: $0)
        return StatusTask(ref: task.ref, title: task.title)
      }
    }
    return report
  }
}
