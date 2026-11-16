import GRDB

extension DocStore {
  static func pending(_ ref: String, workspace: Int64, in db: Database) throws -> Row {
    let (slug, revision) = try DocTriage.selection(ref)
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT r.id,r.doc_id,r.state='proposed' AS proposed FROM doc_rev r
          JOIN doc d ON d.id=r.doc_id WHERE d.workspace_id=? AND d.slug=? AND r.rev=?
          """, arguments: [workspace, slug, revision])
    else { throw DocError.notFound(ref) }
    guard row["proposed"] as Bool else {
      throw DocError.invalid("Only proposed document revisions can be decided.")
    }
    return row
  }

  func reject(_ member: Row) throws {
    try db.execute(
      sql: "UPDATE doc_rev SET state='rejected',triaged_at=?,triaged_by=? WHERE id=?",
      arguments: [utcTimestamp(at), actor.description, member["id"]])
    try transaction.recordChange(kind: "doc", rowID: member["doc_id"])
  }
}
