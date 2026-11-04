import Foundation
import GRDB

/// Local app context and backlog selection within the brief's read transaction.
struct BriefContext {
  let db: Database
  let location: LocationResult
  let actor: ActorID
  let date: Date
  let archiveDays: Int

  func sections(topics requested: [String]) throws -> [BriefSection] {
    let workspace = try TaskService.workspaceID(location.workspace, in: db)
    let tasks = try visibleTasks(workspace: workspace)
    let links = try Row.fetchAll(
      db,
      sql: """
        SELECT link.from_id,topic.id,topic.slug FROM link JOIN topic ON topic.id=link.to_id
        WHERE link.workspace_id=? AND topic.workspace_id=? AND link.from_kind='task'
          AND link.rel='about' AND link.to_kind='topic'
        ORDER BY topic.slug,link.from_id
        """, arguments: [workspace, workspace])
    let appTasks = Set(tasks.filter { location.app != nil && $0.app == location.app }.map(\.id))
    var topics = Set(
      links.filter { appTasks.contains($0["from_id"] as Int64) }.map { $0["id"] as Int64 })
    for word in requested { topics.insert(try topicID(word, workspace: workspace)) }
    let topicTasks = Set(
      links.filter { topics.contains($0["id"] as Int64) }.map { $0["from_id"] as Int64 })
    let matching = tasks.filter { appTasks.contains($0.id) || topicTasks.contains($0.id) }
    var sections = try appSections()
    sections += matching.filter {
      ["proposed", "todo", "doing", "review", "blocked"].contains($0.status)
    }.prefix(8).map {
      BriefSection(
        id: "open_tasks",
        text: "open: \($0.ref) [\($0.status), p\($0.priority)] \(TaskError.shown($0.title))\n")
    }
    sections += matching.filter { $0.status == "done" }.sorted {
      (($0.closedAt ?? ""), sequence($0)) > (($1.closedAt ?? ""), sequence($1))
    }.prefix(5).map {
      let first =
        ($0.result ?? "").split(separator: "\n", omittingEmptySubsequences: false).first.map(
          String.init) ?? ""
      return BriefSection(
        id: "recently_done",
        text: "done: \($0.ref) \(TaskError.shown(first)) (done_sha: \($0.doneSHA ?? "none"))\n")
    }
    sections += try glossary(topics, workspace: workspace)
    return sections
  }

  private func topicID(_ word: String, workspace: Int64) throws -> Int64 {
    guard
      let id = try Int64.fetchOne(
        db,
        sql: """
          SELECT topic.id FROM topic LEFT JOIN topic_alias ON topic_alias.topic_id=topic.id
          WHERE topic.workspace_id=? AND (topic.slug=? OR topic_alias.alias=?)
          ORDER BY (topic.slug=?) DESC,topic.slug LIMIT 1
          """, arguments: [workspace, word, WorkspaceConfig.normalize(word), word])
    else {
      throw CommandFailure(
        error: TaskError.notFound("topic " + word),
        next: [workspaceCommand("silta ws show", workspace: location.workspace)])
    }
    return id
  }

  private func visibleTasks(workspace: Int64) throws -> [TaskDetails] {
    return try Row.fetchAll(
      db,
      sql: TaskService.query + """
        \nWHERE task.workspace_id=? AND task.external_ref IS NULL
        ORDER BY task.priority,task.seq
        """, arguments: [workspace]
    ).map { TaskDetails(row: $0) }.filter { task in
      if task.archiveOverride == "archived" { return false }
      if task.status == "proposed", !actor.isHuman, task.createdBy != actor.description {
        return false
      }
      if task.archiveOverride == nil, ["done", "dropped"].contains(task.status),
        let closed = task.closedAt,
        closed < TaskService.timestamp(date.addingTimeInterval(-Double(archiveDays) * 86400))
      {
        return false
      }
      return true
    }
  }

  private func glossary(_ topics: Set<Int64>, workspace: Int64) throws -> [BriefSection] {
    var sections: [BriefSection] = []
    for topic in try Row.fetchAll(
      db, sql: "SELECT id,slug FROM topic WHERE workspace_id=? ORDER BY slug",
      arguments: [workspace])
    {
      let id: Int64 = topic["id"]
      guard topics.contains(id) else { continue }
      let slug: String = topic["slug"]
      let aliases = try String.fetchAll(
        db, sql: "SELECT alias FROM topic_alias WHERE topic_id=? ORDER BY alias", arguments: [id])
      if !aliases.isEmpty {
        sections.append(
          BriefSection(
            id: "glossary",
            text:
              "glossary: \(TaskError.shown(slug)) = \(aliases.map(TaskError.shown).joined(separator: ", "))\n"
          ))
      }
    }
    return sections
  }

  private func sequence(_ task: TaskDetails) -> Int64 {
    task.ref.split(separator: "-").last.flatMap { Int64($0) } ?? 0
  }

  private func appSections() throws -> [BriefSection] {
    guard let app = location.app,
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT app.id,app.summary FROM app JOIN workspace ON workspace.id=app.workspace_id
          WHERE workspace.slug=? AND app.slug=?
          """, arguments: [location.workspace, app])
    else { return [] }
    let id: Int64 = row["id"]
    var sections = [BriefSection(id: "app", text: "app: \(TaskError.shown(app))\n")]
    if let summary: String = row["summary"], !summary.isEmpty {
      sections.append(
        BriefSection(id: "app", text: "summary: \(TaskError.shown(summary))\n", policy: .characters)
      )
    }
    for environment in try Row.fetchAll(
      db, sql: "SELECT name,url FROM environment WHERE app_id=? ORDER BY name,id", arguments: [id])
    {
      let url: String = environment["url"] ?? ""
      sections.append(
        BriefSection(
          id: "environments",
          text:
            "environment: \(TaskError.shown(environment["name"]))\(url.isEmpty ? "" : " " + TaskError.shown(url))\n"
        ))
    }
    sections.append(
      BriefSection(
        id: "agents", text: "AGENTS.md: \(TaskError.shown(location.worktree + "/AGENTS.md"))\n"))
    return sections + (try neighbours(id: id, app: app))
  }

  private func neighbours(id: Int64, app: String) throws -> [BriefSection] {
    var sections: [BriefSection] = []
    for edge in try Row.fetchAll(
      db,
      sql: """
        SELECT edge.*,source.slug AS source,target.slug AS target,service.slug AS service
        FROM edge JOIN app source ON source.id=edge.from_app_id
        LEFT JOIN app target ON target.id=edge.to_app_id
        LEFT JOIN service ON service.id=edge.to_service_id
        WHERE edge.from_app_id=? OR edge.to_app_id=?
        ORDER BY source.slug,target.slug,service.slug,edge.kind,edge.id
        """, arguments: [id, id])
    {
      let source: String = edge["source"]
      let target: String = edge["target"] ?? "service:" + (edge["service"] as String? ?? "")
      let fallback = source == app ? (edge["target"] as String? ?? source) : source
      var commands: [String] = []
      do {
        for ref in try JSONDecoder().decode(
          [String].self, from: Data((edge["code_refs"] as String).utf8))
        {
          do { commands.append(try codeCommand(ref)) } catch {
            // Invalid stored code evidence falls back to a directory read.
          }
        }
      } catch {}  // Malformed stored code evidence falls back to a directory read.
      if commands.isEmpty {
        commands = [
          CodeRead.list(nil).command(workspace: location.workspace, target: fallback, prod: false)
        ]
      }
      let text =
        "neighbour: \(TaskError.shown(source)) -> \(TaskError.shown(target)) [\(TaskError.shown(edge["kind"]))] \(TaskError.shown(edge["summary"]))\n"
        + commands.map { "next: " + $0 + "\n" }.joined()
      sections.append(BriefSection(id: "neighbours", text: text))
    }
    return sections
  }

  private func codeCommand(_ raw: String) throws -> String {
    let value =
      try TaskLinkTarget.code(
        raw, workspace: TaskService.workspaceID(location.workspace, in: db), in: db
      ).external ?? ""
    let parts = value.split(separator: ":", maxSplits: 1)
    let file = parts[1].split(separator: "#", maxSplits: 1)
    let lines = file.count == 2 ? String(file[1].dropFirst()) : nil
    return CodeRead.show(String(file[0]), lines: lines).command(
      workspace: location.workspace, target: String(parts[0]), prod: false)
  }
}
