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
        workspace: slug,
        item: try TaskLinkTarget.render(
          Row(["to_kind": table, "to_id": id, "to_ext": nil, "anchor": nil]), in: db),
        docs: docs.map { "doc:" + $0 })
    }
    // These links do not pin the target; remove them before its integer id can be reused.
    try db.execute(
      sql: """
        DELETE FROM link WHERE workspace_id=? AND from_kind='doc' AND to_kind=? AND to_id=?
        """, arguments: [workspace, table, id])
  }

}
