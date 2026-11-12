import GRDB

extension WorkspaceConfig {
  func prepareDocRemoval(of table: String, id: Int64, workspace: Int64, in db: Database) throws {
    let docs = try String.fetchAll(
      db,
      sql: """
        SELECT DISTINCT doc.slug FROM link
        JOIN doc ON link.from_kind='doc' AND link.from_id=doc.id
        JOIN doc_rev ON doc_rev.doc_id=doc.id AND doc_rev.rev=doc.current_rev
        WHERE link.workspace_id=? AND doc.workspace_id=? AND link.rel='about'
          AND link.to_kind=? AND link.to_id=? AND doc.archived=0 AND doc_rev.state='accepted'
        ORDER BY doc.slug
        """, arguments: [workspace, workspace, table, id])
    if !docs.isEmpty {
      throw WorkspaceError.docAttachments(
        workspace: slug, item: try Self.attachmentRef(table, id: id, in: db),
        docs: docs.map { "doc:" + $0 })
    }
    // These links do not pin the target; remove them before its integer id can be reused.
    try db.execute(
      sql: """
        DELETE FROM link WHERE workspace_id=? AND from_kind='doc' AND to_kind=? AND to_id=?
        """, arguments: [workspace, table, id])
  }

  private static func attachmentRef(_ table: String, id: Int64, in db: Database) throws -> String {
    if table != "edge" {
      guard
        let slug = try String.fetchOne(
          db, sql: "SELECT slug FROM \(table) WHERE id=?", arguments: [id])
      else { throw StorageError.corrupt }
      return table + ":" + slug
    }
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT source.slug AS source,target.slug AS target,service.slug AS service,edge.kind
          FROM edge JOIN app source ON source.id=edge.from_app_id
          LEFT JOIN app target ON target.id=edge.to_app_id
          LEFT JOIN service ON service.id=edge.to_service_id WHERE edge.id=?
          """, arguments: [id])
    else { throw StorageError.corrupt }
    let service: String? = row["service"]
    let app: String? = row["target"]
    guard let target = service.map({ "service:" + $0 }) ?? app else { throw StorageError.corrupt }
    let source: String = row["source"]
    let kind: String = row["kind"]
    return "edge:" + source + "/" + target + "/" + kind
  }
}
