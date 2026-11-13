import Foundation
import GRDB

/// Lightweight SQL selection: topic membership is one hop and limits precede row decoding.
struct BriefBacklog {
  let db: Database
  let location: LocationResult
  let actor: ActorID
  let date: Date
  let archiveDays: Int

  /// Rows whose `closed_at` cannot be read are left out, and a body-free warning counts them.
  func sections(topics requested: [String]) throws
    -> (sections: [BriefSection], warnings: [OutputWarning])
  {
    let workspace = try TaskService.workspaceID(location.workspace, in: db)
    let visibility = TaskVisibility(actor: actor, at: date, days: archiveDays)
    var arguments = visibility.arguments
    arguments += ["workspace": workspace, "app": location.app]
    let explicit = try Set(requested.map { try topicID($0, workspace: workspace) })
    let inferred = try Int64.fetchAll(
      db,
      sql: """
        SELECT DISTINCT link.to_id FROM link JOIN task ON task.id=link.from_id
        JOIN app ON app.id=task.app_id
        WHERE task.workspace_id=:workspace AND app.slug=:app AND \(TaskVisibility.sql)
          AND link.workspace_id=:workspace AND link.from_kind='task'
          AND link.rel='about' AND link.to_kind='topic'
        """, arguments: arguments)
    let topics = explicit.union(inferred)
    let aliases = try topicRows(topics, workspace: workspace)
    let scope = "(app.slug=:app OR \(topicMatch(topics)))"
    let unreadable = try TaskVisibility.unreadableDates(
      scope: "task.workspace_id=:workspace AND \(scope)",
      arguments: arguments, in: db)
    let warnings =
      unreadable == 0
      ? []
      : [
        OutputWarning(
          code: "closed_at_unreadable",
          message:
            "Left out \(unreadable) \(unreadable == 1 ? "task" : "tasks") with an unreadable closed_at."
        )
      ]
    // The status filter comes first so rows of other statuses skip the archive function.
    let base = { (status: String) in
      """
      FROM task LEFT JOIN app ON app.id=task.app_id
      WHERE \(status) AND task.workspace_id=:workspace AND \(TaskVisibility.sql) AND \(scope)
      """
    }
    let prefix =
      try String.fetchOne(
        db, sql: "SELECT task_prefix FROM workspace WHERE id=?", arguments: [workspace]) ?? ""
    return (
      try taskSections(
        base: base, arguments: arguments, explicit: explicit,
        prefix: prefix, aliases: aliases) + glossary(rows: aliases),
      warnings
    )
  }

  private func taskSections(
    base: (String) -> String, arguments: StatementArguments,
    explicit: Set<Int64>, prefix: String, aliases: [Row]
  ) throws -> [BriefSection] {
    let open = "task.status IN ('proposed','todo','doing','review','blocked')"
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT task.seq,task.title,task.status,task.priority,app.slug AS app
        \(base(open))
        ORDER BY (\(topicMatch(explicit))) DESC,task.priority,task.seq LIMIT 8
        """, arguments: arguments)
    var sections = rows.map { openSection($0, prefix: prefix) }
    let count =
      try Int.fetchOne(db, sql: "SELECT count(*) \(base(open))", arguments: arguments) ?? 0
    if count > rows.count {
      let commands = listCommands(rows: aliases)
      sections.append(
        BriefSection(
          id: "open_more",
          text: "\(count - rows.count) more open:\n"
            + commands.map { "next: " + $0 + "\n" }.joined()))
    }
    let done = try Row.fetchAll(
      db,
      sql: """
        SELECT task.seq,
          substr(task.result_md,1,instr(task.result_md||char(10),char(10))-1) AS result,
          substr(task.done_sha,1,12) AS sha
        \(base("task.status='done' AND " + TaskVisibility.readableOverrideSQL))
        ORDER BY silta_archive_instant(task.closed_at) DESC,task.seq DESC LIMIT 5
        """, arguments: arguments)
    sections += done.map { doneSection($0, prefix: prefix) }
    return sections
  }

  private func doneSection(_ row: Row, prefix: String) -> BriefSection {
    let result: String = row["result"] ?? ""
    let sha: String? = row["sha"]
    let text =
      "done: \(prefix)-\(row["seq"] as Int64)"
      + (result.isEmpty ? "" : " " + TaskError.shown(result))
      + (sha.map { " (done_sha: " + $0 + ")" } ?? "") + "\n"
    return BriefSection(id: "recently_done", text: text)
  }

  private func topicMatch(_ topics: Set<Int64>) -> String {
    guard !topics.isEmpty else { return "0=1" }
    let ids = topics.sorted().map(String.init).joined(separator: ",")
    return """
      EXISTS(SELECT 1 FROM link WHERE link.workspace_id=:workspace
        AND link.from_kind='task' AND link.from_id=task.id AND link.rel='about'
        AND link.to_kind='topic' AND link.to_id IN (\(ids)))
      """
  }

  func topicID(_ word: String, workspace: Int64) throws -> Int64 {
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

  private func openSection(_ row: Row, prefix: String) -> BriefSection {
    let app: String? = row["app"]
    let label = app != location.app ? " (app: \(app ?? "unbound"))" : ""
    return BriefSection(
      id: "open_tasks",
      text:
        "open: \(prefix)-\(row["seq"] as Int64) [\(row["status"] as String), p\(row["priority"] as Int)] \(TaskError.shown(row["title"]))\(label)\n"
    )
  }

  private func topicRows(_ topics: Set<Int64>, workspace: Int64) throws -> [Row] {
    guard !topics.isEmpty else { return [] }
    let ids = topics.sorted().map(String.init).joined(separator: ",")
    return try Row.fetchAll(
      db,
      sql: """
        SELECT topic.id,topic.slug,topic_alias.alias FROM topic
        LEFT JOIN topic_alias ON topic_alias.topic_id=topic.id
        WHERE topic.workspace_id=? AND topic.id IN (\(ids)) ORDER BY topic.slug,topic_alias.alias
        """, arguments: [workspace])
  }

  private func listCommands(rows: [Row]) -> [String] {
    let command = "silta --ws " + shellWord(location.workspace) + " task ls"
    var commands = location.app.map { [command + " --app " + shellWord($0)] } ?? []
    let slugs = rows.map { $0["slug"] as String }
    for slug in Set(slugs).sorted() { commands.append(command + " --topic " + shellWord(slug)) }
    return commands
  }

  private func glossary(rows: [Row]) -> [BriefSection] {
    let grouped = Dictionary(grouping: rows, by: { $0["slug"] as String })
    return grouped.keys.sorted().compactMap { slug in
      let aliases = (grouped[slug] ?? []).compactMap { $0["alias"] as String? }
      guard !aliases.isEmpty else { return nil }
      return BriefSection(
        id: "glossary",
        text:
          "glossary: \(TaskError.shown(slug)) = \(aliases.map(TaskError.shown).joined(separator: ", "))\n"
      )
    }
  }
}
