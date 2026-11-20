import Foundation
import GRDB

extension TaskLinkTarget {
  /// Resolves an attachment to a map identity inside one workspace.
  static func map(_ raw: String, workspace: Int64, in db: Database) throws -> Self {
    guard
      let slug = try String.fetchOne(
        db, sql: "SELECT slug FROM workspace WHERE id=?", arguments: [workspace])
    else {
      throw WorkspaceError.notFound
    }
    do {
      let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw TaskError.invalid("Use a typed map reference.") }
      let kind = String(parts[0])
      let value = String(parts[1])
      if kind == "edge" { return try edge(value, workspace: workspace, in: db) }
      guard ["app", "service", "topic"].contains(kind) else {
        throw TaskError.invalid("Use app:, edge:, service: or topic: attachment references.")
      }
      if kind == "topic" { return try topic(value, workspace: workspace, in: db) }
      if kind == "app" {
        let name = try identifier(value)
        let app = try TaskService.namedSlug(.app, name, workspace: workspace, in: db)
        return Self(
          kind: kind, id: app.id, warnings: [app.warning(for: name, kind: .app)].compactMap { $0 })
      }
      let name = try decodeComponent(value)
      return Self(
        kind: kind, id: try TaskService.entity(kind, slug: name, workspace: workspace, in: db))
    } catch let error as TaskError {
      var next = [workspaceCommand("silta ws show", workspace: slug)]
      if WorkspaceConfig.isValidIdentifier(raw), DocService.safeReference("app:" + raw),
        try Int.fetchOne(
          db, sql: "SELECT count(*) FROM app WHERE workspace_id=? AND slug=?",
          arguments: [workspace, raw]) == 1
      {
        next = [
          workspaceCommand("silta doc ls --about " + shellWord("app:" + raw), workspace: slug)
        ]
      }
      throw CommandFailure(error: error, next: next)
    }
  }

  private static func topic(_ value: String, workspace: Int64, in db: Database) throws -> Self {
    guard let topic = try WorkspaceSlugs.topic(value, workspace: workspace, in: db)
    else { throw TaskError.notFound("topic " + value) }
    return Self(
      kind: "topic", id: topic.id,
      warnings: [topic.warning(for: value, kind: .topic)].compactMap { $0 })
  }

  private static func edge(_ raw: String, workspace: Int64, in db: Database) throws -> Self {
    let pieces = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard pieces.count == 3 else {
      throw TaskError.invalid(
        "Use edge:<from>/<to>/<kind>, retaining service: for a service target.")
    }
    let source = try TaskService.namedSlug(
      .app, identifier(pieces[0]), workspace: workspace, in: db)
    let service = pieces[1].hasPrefix("service:")
    let name =
      service ? try decodeComponent(String(pieces[1].dropFirst(8))) : try identifier(pieces[1])
    let app = try service ? nil : TaskService.namedSlug(.app, name, workspace: workspace, in: db)
    let target =
      try app?.id ?? TaskService.entity("service", slug: name, workspace: workspace, in: db)
    let kind = try decodeComponent(pieces[2])
    guard
      let id = try Int64.fetchOne(
        db,
        sql: """
          SELECT id FROM edge WHERE workspace_id=? AND from_app_id=?
            AND to_app_id IS ? AND to_service_id IS ? AND kind=CAST(? AS TEXT)
          """,
        arguments: [
          workspace, source.id, service ? nil : target, service ? target : nil, Data(kind.utf8),
        ])
    else {
      throw TaskError.notFound("edge " + raw)
    }
    return Self(
      kind: "edge", id: id,
      warnings: [
        source.warning(for: pieces[0], kind: .app), app?.warning(for: name, kind: .app),
      ].compactMap { $0 })
  }

  private static func identifier(_ value: String) throws -> String {
    guard WorkspaceConfig.isValidIdentifier(value) else {
      throw TaskError.invalid("Use an identifier for an app or topic in a map reference.")
    }
    return value
  }

  private static func decodeComponent(_ value: String) throws -> String {
    guard !value.isEmpty, let decoded = value.removingPercentEncoding,
      encodeComponent(decoded) == value
    else {
      throw TaskError.invalid("Use canonical uppercase percent escapes in map references.")
    }
    return decoded
  }
}
