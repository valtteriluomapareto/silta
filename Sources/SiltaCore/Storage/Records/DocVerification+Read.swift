import GRDB

extension DocVerification {
  static func binding(_ metadata: DocMetadata, workspace: Int64, in db: Database) throws -> Binding
  {
    let cursor = try Row.fetchCursor(
      db, sql: "SELECT uid,slug FROM workspace WHERE id=?", arguments: [workspace])
    defer { withExtendedLifetime(cursor) {} }
    guard let row = try cursor.next() else { throw WorkspaceError.notFound }
    guard let workspaceUID = try StoredUID.read(from: row) else { throw StoredUID.unsupported }
    var targets: [TargetBinding] = []
    var appIDs: Set<Int64> = []
    for target in metadata.targets {
      guard let id = target.id,
        let uid = try StoredUID.fetch(
          db, sql: "SELECT uid FROM \(target.kind) WHERE workspace_id=? AND id=?",
          arguments: [workspace, id])
      else { throw StorageError.corrupt }
      var serviceUID: String?
      if target.kind == "app" { appIDs.insert(id) }
      if target.kind == "edge" {
        let edges = try Row.fetchCursor(
          db,
          sql: """
            SELECT edge.from_app_id,edge.to_app_id,service.uid AS service_uid
            FROM edge LEFT JOIN service ON service.id=edge.to_service_id WHERE edge.id=?
            """, arguments: [id])
        defer { withExtendedLifetime(edges) {} }
        guard let edge = try edges.next() else { throw StorageError.corrupt }
        appIDs.insert(edge["from_app_id"])
        if let app: Int64 = edge["to_app_id"] { appIDs.insert(app) }
        serviceUID = try StoredUID.read("service_uid", from: edge)
      }
      targets.append(TargetBinding(kind: target.kind, uid: uid, serviceUID: serviceUID))
    }
    let apps = try appIDs.map { try appBinding($0, workspace: workspace, in: db) }
      .sorted { $0.app < $1.app }
    return Binding(
      workspace: row["slug"], workspaceUID: workspaceUID, title: metadata.title,
      kind: metadata.kind, about: metadata.refs, targets: targets, apps: apps)
  }

  private static func appBinding(_ id: Int64, workspace: Int64, in db: Database) throws
    -> AppBinding
  {
    let cursor = try Row.fetchCursor(
      db,
      sql: """
        SELECT app.uid,app.slug AS app,app.ref,app.subpath,repo.uid AS repo_uid,
          repo.slug AS repo,repo_path.path
        FROM app JOIN repo ON repo.id=app.repo_id
        LEFT JOIN repo_path ON repo_path.repo_id=repo.id
        WHERE app.workspace_id=? AND app.id=?
        """, arguments: [workspace, id])
    defer { withExtendedLifetime(cursor) {} }
    guard let app = try cursor.next() else { throw StorageError.corrupt }
    guard let uid = try StoredUID.read(from: app),
      let repoUID = try StoredUID.read("repo_uid", from: app)
    else { throw StoredUID.unsupported }
    return AppBinding(
      app: app["app"], uid: uid, ref: app["ref"], repo: app["repo"],
      repoUID: repoUID, path: app["path"], subpath: app["subpath"])
  }
}
