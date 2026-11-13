import Foundation
import GRDB

/// Local app context and backlog selection within the brief's read transaction.
struct BriefContext {
  let db: Database
  let location: LocationResult
  let actor: ActorID
  let date: Date
  let archiveDays: Int

  func sections(topics requested: [String], compact: Bool = false) throws
    -> (sections: [BriefSection], warnings: [OutputWarning])
  {
    let reader = BriefBacklog(
      db: db, location: location, actor: actor, date: date, archiveDays: archiveDays)
    let backlog = try reader.sections(topics: requested)
    let workspace = try TaskService.workspaceID(location.workspace, in: db)
    let explicit = try Set(requested.map { try reader.topicID($0, workspace: workspace) })
    let docs = try BriefDocs(db: db, location: location, topics: explicit, compact: compact)
    let app = try appSections(documents: docs)
    var sections = app + backlog.sections
    let topics = try docs.topicGroups()
    if !topics.isEmpty {
      let beforeGlossary =
        backlog.sections.firstIndex { $0.id == "glossary" } ?? backlog.sections.count
      sections.insert(
        BriefSection(id: "docs", text: "", documents: topics), at: app.count + beforeGlossary)
    }
    return (sections, backlog.warnings)
  }

  private func appSections(documents: BriefDocs) throws -> [BriefSection] {
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
    if let group = try documents.group(kind: "app", id: id) {
      sections[sections.count - 1].documents = [group]
    }
    return sections + (try neighbours(id: id, app: app, documents: documents))
  }

  private func neighbours(id: Int64, app: String, documents: BriefDocs) throws -> [BriefSection] {
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
      let edgeID: Int64 = edge["id"]
      let ref = try TaskLinkTarget(kind: "edge", id: edgeID).rendered(in: db)
      let text =
        "neighbour: \(BriefDocGroup.shown(ref)) \(TaskError.shown(edge["summary"]))\n"
        + commands.map { "next: " + $0 + "\n" }.joined()
      var groups = try documents.group(kind: "edge", id: edgeID).map { [$0] } ?? []
      if let service: Int64 = edge["to_service_id"],
        let group = try documents.group(kind: "service", id: service)
      {
        groups.append(group)
      }
      sections.append(BriefSection(id: "neighbours", text: text, documents: groups))
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
