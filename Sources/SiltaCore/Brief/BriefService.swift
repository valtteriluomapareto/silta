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
    topics: [String] = [], budget: Int = 2500, short: Bool = false, hook: Bool = false
  ) async throws -> BriefReport {
    let location = try await LocationService(environment: environment).resolve(
      path: path, workspace: workspace, app: app, task: task, cacheWrites: !hook)
    let now = environment.clock.now()
    var report = try environment.db.read {
      try self.report(
        location, app: app, topics: topics, budget: budget, compact: short || hook, at: now, in: $0)
    }
    await addEdgeCommands(to: &report, workspace: location.workspace)
    report.trim(tokens: budget)
    report.insertDocuments(tokens: budget)
    return report
  }

  /// Captures brief data in the caller's read snapshot before any edge probes.
  func report(
    _ location: LocationResult, app: String? = nil, topics: [String] = [], budget: Int = 2500,
    compact: Bool = false, at now: Date, in db: Database
  ) throws -> BriefReport {
    let command = "silta --ws " + shellWord(location.workspace)
    let characters = BriefBudget.characters(tokens: budget)
    let id = try TaskService.workspaceID(location.workspace, in: db)
    let settings = BriefSettings(
      try WorkspaceSettings.read(workspaceID: id, in: db), workspace: location.workspace)
    var selected = try location.currentTask.map {
      try TaskService.lookup($0.ref, workspace: location.workspace, in: db)
    }
    if let current = selected {
      selected?.waiting = try TaskService.waiting(current, at: now, in: db)
    }
    let discussion = try BriefDiscussion(
      db: db, service: TaskService(environment: environment, workspace: location.workspace),
      caller: environment.actor, workspace: location.workspace, command: command,
      current: selected, now: now, characters: characters
    ).sections()
    let context = try BriefContext(
      db: db, location: location, actor: environment.actor, date: now,
      archiveDays: settings.archiveAfterDays ?? WorkspaceSettings.defaultArchiveAfterDays
    ).sections(topics: topics, compact: compact)
    let selection =
      (app.map { " --app " + shellWord($0) } ?? "")
      + topics.map { " --topic " + shellWord($0) }.joined()
    let more =
      (selected.map {
        (budget < 2500 ? [command + " brief --task " + $0.ref + selection] : [])
          + [command + " task show " + $0.ref]
      }
        ?? [command + " task ls", command + " ws show"])
      + (discussion.inbox.isEmpty ? [] : [command + " inbox"])
    return BriefReport(
      location: BriefLocation(location), settings: settings,
      currentTask: selected?.ref,
      sections: sections(
        location, current: selected, topics: topics,
        discussion: discussion.task, characters: characters)
        + discussion.inbox + context.sections,
      more: more, warnings: location.warnings + settings.warnings + context.warnings)
  }

  private func addEdgeCommands(to report: inout BriefReport, workspace: String) async {
    let git: any GitRunner =
      if let hook = environment.git as? BriefHookGitRunner { hook.optionalReads() } else {
        environment.git
      }
    var probe = EdgeCodeEvidence(workspace: workspace, environment: environment, git: git)
    var emitted: Set<Data> = []
    for index in report.sections.indices {
      guard let references = report.sections[index].edgeCodeRefs else { continue }
      var needsInspection = references.isEmpty
      for reference in references {
        guard let command = await probe.command(reference) else {
          needsInspection = true
          continue
        }
        if emitted.insert(Data(command.utf8)).inserted {
          report.sections[index].text += "next: " + command + "\n"
        }
      }
      if needsInspection, emitted.insert(Data(probe.inspect.utf8)).inserted {
        report.sections[index].text += "next: " + probe.inspect + "\n"
      }
      report.sections[index].edgeCodeRefs = nil
    }
  }

  private func sections(
    _ location: LocationResult, current: TaskDetails?, topics: [String],
    discussion: [BriefSection], characters: Int
  )
    -> [BriefSection]
  {
    let command = "silta --ws " + shellWord(location.workspace)
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
      sections += discussion
      if let waiting = current.waiting {
        let error = TaskError.blocked(current.ref, waiting)
        let next = error.next.map { workspaceCommand($0, workspace: location.workspace) }
        let followUp = current.followUpAt.map { "follow-up: " + $0 + "\n" } ?? ""
        sections.append(
          BriefSection(
            id: "blockers",
            text:
              error.message + "\n" + BriefDiscussion.quoted(waiting.why) + followUp
              + next.map { "next: " + $0 + "\n" }.joined()
          ))
      }
      if !current.plan.isEmpty {
        sections.append(
          BriefPlan.section(current.plan, ref: current.ref, revision: current.planRev))
      }
      if !current.description.isEmpty {
        sections.append(description(current, command: command, characters: characters))
      }
    }
    return sections
  }

  /// The description takes 6% of a larger budget and at most 600 characters otherwise;
  /// below the default the global budget trims it.
  private func description(_ current: TaskDetails, command: String, characters: Int)
    -> BriefSection
  {
    let marker = "(description trimmed; \(command) task show \(current.ref))\n"
    let text =
      "description:\n"
      + HumanText.body(current.description)
      .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    return BriefBudget.capped(
      BriefSection(id: "description", text: text, policy: .excerpt(marker: marker)),
      characters: max(600, BriefBudget.share(6, of: characters)))
  }
}
