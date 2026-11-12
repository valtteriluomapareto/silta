import Foundation
import GRDB

/// Local app context and backlog selection within the brief's read transaction.
struct BriefContext {
  let db: Database
  let location: LocationResult
  let actor: ActorID
  let date: Date
  let archiveDays: Int

  func sections(topics requested: [String]) throws
    -> (sections: [BriefSection], warnings: [OutputWarning])
  {
    let backlog = try BriefBacklog(
      db: db, location: location, actor: actor,
      date: date, archiveDays: archiveDays
    ).sections(topics: requested)
    return (try appSections() + backlog.sections, backlog.warnings)
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
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(
      atPath: location.worktree + "/AGENTS.md", isDirectory: &isDirectory),
      !isDirectory.boolValue
    {
      sections.append(
        BriefSection(
          id: "agents",
          text:
            "AGENTS.md: \(TaskError.shown((location.displayWorktree ?? location.worktree) + "/AGENTS.md"))\n"
        ))
    }
    return sections + (try neighbours(id: id, app: app))
  }

  private func neighbours(id: Int64, app: String) throws -> [BriefSection] {
    var sections: [BriefSection] = []
    var emitted: Set<String> = []
    let workspace = try TaskService.workspaceID(location.workspace, in: db)
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
        for value
          in (try JSONSerialization.jsonObject(with: Data((edge["code_refs"] as String).utf8))
          as? [Any]) ?? []
        {
          guard let ref = value as? String else { continue }
          do { commands.append(try codeCommand(ref, workspace: workspace)) } catch {
            // Invalid stored code evidence falls back to a directory read.
          }
        }
      } catch {}  // Malformed stored code evidence falls back to a directory read.
      if commands.isEmpty, fallback != app {
        commands = [
          CodeRead.list(nil).command(workspace: location.workspace, target: fallback, prod: false)
        ]
      }
      commands = commands.filter { emitted.insert($0).inserted }
      let text =
        "neighbour: \(TaskError.shown(source)) -> \(TaskError.shown(target)) [\(TaskError.shown(edge["kind"]))] \(TaskError.shown(edge["summary"]))\n"
        + commands.map { "next: " + $0 + "\n" }.joined()
      sections.append(BriefSection(id: "neighbours", text: text))
    }
    return sections
  }

  private func codeCommand(_ raw: String, workspace: Int64) throws -> String {
    // The configured field already identifies code; retain its stored spelling.
    let reference = raw.hasPrefix("code:") ? raw : "code:" + raw
    let value =
      try TaskLinkTarget.code(
        reference, workspace: workspace, in: db
      ).external ?? ""
    let parts = value.split(separator: ":", maxSplits: 1)
    let file = parts[1].split(separator: "#", maxSplits: 1)
    let lines = file.count == 2 ? String(file[1].dropFirst()) : nil
    return CodeRead.show(String(file[0]), lines: lines).command(
      workspace: location.workspace, target: String(parts[0]), prod: false)
  }
}
