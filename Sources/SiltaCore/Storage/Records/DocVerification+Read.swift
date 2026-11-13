import GRDB

extension DocVerification {
  static func readBinding(_ draft: DocDraft, workspace: Int64, store: DatabaseStore) throws
    -> Binding
  {
    try store.read { db in
      try binding(
        DocMetadata.resolve(draft, workspace: workspace, in: db), workspace: workspace, in: db)
    }
  }

  static func binding(_ metadata: DocMetadata, workspace: Int64, in db: Database) throws -> Binding
  {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT uid,slug FROM workspace WHERE id=?", arguments: [workspace])
    else {
      throw WorkspaceError.notFound
    }
    var targets: [TargetBinding] = []
    var appIDs: Set<Int64> = []
    for target in metadata.targets {
      guard let id = target.id,
        let uid = try String.fetchOne(
          db,
          sql: "SELECT uid FROM \(target.kind) WHERE workspace_id=? AND id=?",
          arguments: [workspace, id])
      else {
        throw StorageError.corrupt
      }
      var serviceUID: String?
      if target.kind == "app" { appIDs.insert(id) }
      if target.kind == "edge" {
        guard
          let edge = try Row.fetchOne(
            db,
            sql: """
              SELECT edge.from_app_id,edge.to_app_id,service.uid AS service_uid
              FROM edge LEFT JOIN service ON service.id=edge.to_service_id WHERE edge.id=?
              """, arguments: [id])
        else { throw StorageError.corrupt }
        appIDs.insert(edge["from_app_id"])
        if let app: Int64 = edge["to_app_id"] { appIDs.insert(app) }
        serviceUID = edge["service_uid"]
      }
      targets.append(TargetBinding(kind: target.kind, uid: uid, serviceUID: serviceUID))
    }
    let apps = try appIDs.map { id -> AppBinding in
      guard
        let app = try Row.fetchOne(
          db,
          sql: """
            SELECT app.uid,app.slug AS app,app.ref,app.subpath,repo.uid AS repo_uid,
              repo.slug AS repo,repo_path.path
            FROM app JOIN repo ON repo.id=app.repo_id LEFT JOIN repo_path ON repo_path.repo_id=repo.id
            WHERE app.workspace_id=? AND app.id=?
            """, arguments: [workspace, id])
      else { throw StorageError.corrupt }
      return AppBinding(
        app: app["app"], uid: app["uid"], ref: app["ref"], repo: app["repo"],
        repoUID: app["repo_uid"], path: app["path"], subpath: app["subpath"])
    }.sorted { $0.app < $1.app }
    return Binding(
      workspace: row["slug"], workspaceUID: row["uid"], title: metadata.title,
      kind: metadata.kind, about: metadata.refs, targets: targets, apps: apps)
  }
}
