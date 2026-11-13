import GRDB

extension WorkspaceConfig {
  func prepareDocRemoval(of table: String, id: Int64, workspace: Int64, in db: Database) throws {
    let docs = try Row.fetchAll(
      db,
      sql: """
        SELECT DISTINCT doc.id,doc.slug FROM link
        JOIN doc ON link.from_kind='doc' AND link.from_id=doc.id
        JOIN doc_rev ON doc_rev.doc_id=doc.id AND doc_rev.rev=doc.current_rev
        WHERE link.workspace_id=? AND doc.workspace_id=? AND link.rel='about'
          AND link.to_kind=? AND link.to_id=? AND doc.archived=0 AND doc_rev.state='accepted'
        ORDER BY doc.slug
        """, arguments: [workspace, workspace, table, id])
    if !docs.isEmpty {
      let recovery = try docs.map {
        try reattachCommand($0, removing: table, id: id, workspace: workspace, in: db)
      }
      throw WorkspaceError.docAttachments(
        workspace: slug,
        item: try TaskLinkTarget.render(
          Row(["to_kind": table, "to_id": id, "to_ext": nil, "anchor": nil]), in: db),
        docs: docs.map { "doc:" + ($0["slug"] as String) },
        commands: recovery.map(\.command) + [
          SecretGuard.matches(in: slug).isEmpty
            ? workspaceCommand("silta ws show", workspace: slug) : "silta ws ls"
        ], nextBy: recovery.contains { $0.owner == .human } ? .human : .agent)
    }
    // These links do not pin the target; remove them before its integer id can be reused.
    try db.execute(
      sql: """
        DELETE FROM link WHERE workspace_id=? AND from_kind='doc' AND to_kind=? AND to_id=?
        """, arguments: [workspace, table, id])
  }

  private func reattachCommand(
    _ doc: Row, removing kind: String, id: Int64, workspace: Int64,
    in db: Database
  ) throws -> (command: String, owner: NextBy) {
    guard SecretGuard.matches(in: slug).isEmpty else { return ("silta ws ls", .agent) }
    let fallback = workspaceCommand("silta doc ls", workspace: slug)
    let ref = "doc:" + (doc["slug"] as String)
    guard DocService.safeReference(ref) else { return (fallback, .agent) }
    let remaining = try DocStore.attachments(doc["id"], workspace: workspace, in: db)
      .filter { ($0["to_kind"] as String) != kind || ($0["to_id"] as Int64?) != id }
      .map { try TaskLinkTarget.render($0, in: db) }.sorted()
    guard remaining.allSatisfy(DocService.safeReference) else { return (fallback, .agent) }
    let command =
      workspaceCommand("silta doc edit " + shellWord(ref) + " --keep-body", workspace: slug)
      + remaining.map { " --about " + shellWord($0) }.joined()
      + " --about <replacement-ref> --approved \"<the human's words>\""
    return (command, .human)
  }

}
