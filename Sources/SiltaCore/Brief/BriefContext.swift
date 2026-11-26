import Foundation
import GRDB

/// Local app context and backlog selection within the brief's read transaction.
struct BriefContext {
  let db: Database
  let location: BriefLocation
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
    guard let git = location.git, let app = git.app,
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT app.id,app.summary,NULLIF(app.name,app.slug) AS display_name
          FROM app JOIN workspace ON workspace.id=app.workspace_id
          WHERE workspace.slug=? AND app.slug=?
          """, arguments: [location.workspace, app])
    else { return [] }
    let id: Int64 = row["id"]
    let name: String? = row["display_name"]
    let label = name.map { " (" + HumanText.line($0) + ")" } ?? ""
    var sections = [BriefSection(id: "app", text: "app: \(TaskError.shown(app))\(label)\n")]
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
      atPath: git.worktree + "/AGENTS.md", isDirectory: &isDirectory),
      !isDirectory.boolValue
    {
      sections.append(
        BriefSection(
          id: "agents",
          text:
            "AGENTS.md: \(TaskError.shown((git.displayWorktree ?? git.worktree) + "/AGENTS.md"))\n"
        ))
    }
    if let group = try documents.group(kind: "app", id: id) {
      sections[sections.count - 1].documents = [group]
    }
    return sections + (try neighbours(id: id, app: app, documents: documents))
  }

  private func neighbours(id: Int64, app: String, documents: BriefDocs) throws -> [BriefSection] {
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
      let neighbour = source == app ? (edge["target"] as String? ?? source) : source
      let stored: String = edge["code_refs"]
      let references = EdgeCodeEvidence.references(stored)
      let edgeID: Int64 = edge["id"]
      let ref = try TaskLinkTarget(kind: "edge", id: edgeID).rendered(in: db)
      let text = "neighbour: \(BriefDocGroup.shown(ref)) \(TaskError.shown(edge["summary"]))\n"
      var groups = try documents.group(kind: "edge", id: edgeID).map { [$0] } ?? []
      if let service: Int64 = edge["to_service_id"],
        let group = try documents.group(kind: "service", id: service)
      {
        groups.append(group)
      }
      sections.append(
        BriefSection(
          id: "neighbours", text: text, documents: groups,
          edgeCodeRefs: neighbour != app || !references.isEmpty ? references : nil))
    }
    return sections
  }
}
