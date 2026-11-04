package import Foundation
import GRDB

/// Builds local brief context without fetching or mutating truth data.
package struct BriefService {
  let environment: SiltaEnvironment

  /// Construction performs no I/O.
  package init(environment: SiltaEnvironment) { self.environment = environment }

  /// Resolves location, reads current work and fits optional sections to a character budget.
  /// Hook reads may reuse a fresh location cache but never populate it.
  package func resolve(
    path: URL, workspace: String? = nil, app: String? = nil, task: String? = nil,
    budget: Int = 2500, hook: Bool = false
  ) async throws -> BriefReport {
    let location = try await LocationService(environment: environment).resolve(
      path: path, workspace: workspace, app: app, task: task, cacheWrites: !hook)
    let (current, settings) = try environment.db.read { db in
      let id = try TaskService.workspaceID(location.workspace, in: db)
      let settings = try BriefSettings(
        WorkspaceSettings.read(workspaceID: id, in: db), workspace: location.workspace)
      let selected: TaskDetails?
      if let task {
        selected = try TaskService.lookup(task, workspace: location.workspace, in: db)
      } else {
        selected = try currentTask(location, app: app, workspaceID: id, in: db)
      }
      return (
        try selected.map { try TaskService.decorate($0, at: environment.clock.now(), in: db) },
        settings
      )
    }
    let command = "silta --ws " + shellWord(location.workspace)
    let more =
      current.map { [command + " brief --task " + $0.ref, command + " task show " + $0.ref] }
      ?? [command + " task ls", command + " ws show"]
    var report = BriefReport(
      location: BriefLocation(location), settings: settings,
      currentTask: current?.ref, sections: sections(location, current: current, command: command),
      more: more, warnings: location.warnings)
    report.trim(tokens: budget)
    return report
  }

  private func sections(_ location: LocationResult, current: TaskDetails?, command: String)
    -> [BriefSection]
  {
    var sections: [BriefSection] = []
    if location.confidence == "low" {
      sections.append(
        BriefSection(
          id: "candidates",
          text: "candidates: "
            + location.retryCandidates.map { "\($0.app) (\($0.ref))" }.joined(separator: ", ")
            + "\n"))
    }
    if let current {
      sections.append(
        BriefSection(
          id: "task",
          text:
            "\(current.status): \(TaskError.shown(current.title)) (app: \(current.app ?? "unbound"))\n"
        ))
      if let waiting = current.waiting {
        let error = TaskError.blocked(current.ref, waiting)
        let next = error.next.map { command + String($0.dropFirst(5)) }
        sections.append(
          BriefSection(
            id: "blockers",
            text:
              error.message + "\n" + waiting.why + "\n" + next.map { "next: " + $0 + "\n" }.joined()
          ))
      }
      if !current.plan.isEmpty {
        let plan = SecretGuard.redacted(MarkdownPlan.numbered(current.plan))
        sections.append(
          BriefSection(
            id: "plan",
            text:
              "plan (revision \(current.planRev)):\n" + plan + (plan.hasSuffix("\n") ? "" : "\n")))
      }
    }
    return sections
  }

  private func currentTask(
    _ location: LocationResult, app: String?, workspaceID: Int64, in db: Database
  ) throws -> TaskDetails? {
    let candidates = location.candidates.filter { app == nil || app == $0.app }.map(\.id)
    let slots = candidates.map { _ in "?" }.joined(separator: ",")
    let row = try Row.fetchOne(
      db,
      sql: TaskService.query + """
        \nWHERE task.workspace_id=? AND task.status IN ('todo','doing','review','blocked')
          AND task.external_ref IS NULL AND task.archive_override IS NOT 'archived'
          AND ((task.app_id IS NULL AND (task.worktree IS NULL OR task.worktree=?))
            OR task.app_id IN (\(slots)))
          AND (task.claimed_by=? OR task.branch=?)
        ORDER BY COALESCE(task.claimed_by=?,0) DESC,
          CASE WHEN task.claimed_by=? THEN task.claimed_at ELSE task.updated_at END DESC,
          task.seq DESC LIMIT 1
        """,
      arguments: StatementArguments(
        [workspaceID, location.worktree] as [(any DatabaseValueConvertible)?]
          + candidates.map { $0 as (any DatabaseValueConvertible)? }
          + [
            environment.actor.description, location.branch, environment.actor.description,
            environment.actor.description,
          ]))
    return row.map { TaskDetails(row: $0) }
  }
}
