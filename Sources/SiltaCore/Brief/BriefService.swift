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
    topics: [String] = [], budget: Int = 2500, hook: Bool = false
  ) async throws -> BriefReport {
    let location = try await LocationService(environment: environment).resolve(
      path: path, workspace: workspace, app: app, task: task, cacheWrites: !hook)
    let (current, settings, context) = try environment.db.read { db in
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
        selected, settings,
        try BriefContext(
          db: db, location: location, actor: environment.actor,
          date: environment.clock.now(),
          archiveDays: settings.archiveAfterDays ?? WorkspaceSettings.defaultArchiveAfterDays
        ).sections(topics: topics)
      )
    }
    let command = "silta --ws " + shellWord(location.workspace)
    let selection =
      (app.map { " --app " + shellWord($0) } ?? "")
      + topics.map { " --topic " + shellWord($0) }.joined()
    let more =
      current.map {
        (budget < 2500 ? [command + " brief --task " + $0.ref + selection] : [])
          + [command + " task show " + $0.ref]
      }
      ?? [command + " task ls", command + " ws show"]
    var report = BriefReport(
      location: BriefLocation(location), settings: settings,
      currentTask: current?.ref,
      sections: sections(location, current: current, command: command, topics: topics) + context,
      more: more, warnings: location.warnings + settings.warnings)
    report.trim(tokens: budget)
    return report
  }

  private func sections(
    _ location: LocationResult, current: TaskDetails?, command: String, topics: [String]
  )
    -> [BriefSection]
  {
    var sections: [BriefSection] = []
    if location.confidence == "low" {
      let candidates = location.retryCandidates
      if !candidates.isEmpty {
        let line = candidates.map { "\($0.app) (\($0.ref))" }.joined(separator: ", ")
        let retries = candidates.map {
          "next: \(command) brief --app \(shellWord($0.app))"
            + (current.map { " --task " + $0.ref } ?? "")
            + topics.map { " --topic " + shellWord($0) }.joined() + "\n"
        }.joined()
        sections.append(
          BriefSection(
            id: "candidates", text: "candidates: " + line + "\n" + retries, beforeTask: true))
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
    if let current, !current.description.isEmpty {
      sections.append(description(current, command: command))
    }
    return sections
  }

  private func description(_ current: TaskDetails, command: String) -> BriefSection {
    let marker = "(description trimmed; \(command) task show \(current.ref))\n"
    let text =
      "description:\n"
      + SecretGuard.redacted(current.description)
      .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    let section = BriefSection(id: "description", text: text, policy: .excerpt(marker: marker))
    return BriefBudget.trim([section], characters: 600).sections.first
      ?? BriefSection(id: "description", text: marker, truncated: true)
  }

}
