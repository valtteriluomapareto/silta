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
      let settings = BriefSettings(
        try WorkspaceSettings.read(workspaceID: id, in: db), workspace: location.workspace)
      var selected = try location.currentTask.map {
        try TaskService.lookup($0.ref, workspace: location.workspace, in: db)
      }
      if let current = selected {
        selected?.waiting = try TaskService.waiting(current, at: environment.clock.now(), in: db)
      }
      return (
        selected,
        settings
      )
    }
    let command = "silta --ws " + shellWord(location.workspace)
    let more =
      current.map {
        (budget < 2500 ? [command + " brief --task " + $0.ref] : [])
          + [command + " task show " + $0.ref]
      }
      ?? [command + " task ls", command + " ws show"]
    var report = BriefReport(
      location: BriefLocation(location), settings: settings,
      currentTask: current?.ref, sections: sections(location, current: current, command: command),
      more: more, warnings: location.warnings + settings.warnings)
    report.trim(tokens: budget)
    return report
  }

  private func sections(_ location: LocationResult, current: TaskDetails?, command: String)
    -> [BriefSection]
  {
    var sections: [BriefSection] = []
    if location.confidence == "low" {
      for candidate in location.retryCandidates {
        sections.append(
          BriefSection(
            id: "candidates",
            text: "candidates: \(candidate.app) (\(candidate.ref))\n"
              + "next: \(command) brief --app \(shellWord(candidate.app))\n"))
      }
    }
    if let current {
      sections.append(
        BriefSection(
          id: "task",
          text:
            "\(current.status): \(TaskError.shown(current.title)) (app: \(current.app ?? "unbound"))\n",
          policy: .characters
        ))
      if let waiting = current.waiting {
        let error = TaskError.blocked(current.ref, waiting)
        let next = error.next.map { workspaceCommand($0, workspace: location.workspace) }
        let followUp = current.followUpAt.map { "follow-up: " + $0 + "\n" } ?? ""
        sections.append(
          BriefSection(
            id: "blockers",
            text:
              error.message + "\n" + waiting.why + "\n" + followUp
              + next.map { "next: " + $0 + "\n" }.joined()
          ))
      }
      if !current.plan.isEmpty {
        sections.append(
          BriefPlan.section(current.plan, ref: current.ref, revision: current.planRev))
      }
    }
    return sections
  }

}
