import GRDB

extension DocService {
  private static let commentQuery = """
    SELECT c.*,(SELECT to_ext FROM link WHERE from_kind='comment' AND from_id=c.id
      AND rel='cites' AND to_kind='note' ORDER BY id LIMIT 1) AS source,
    r.seq AS root_seq,r.resolved_at AS root_resolved_at,r.resolved_by AS root_resolved_by
    FROM comment c LEFT JOIN comment r ON r.id=c.thread_id AND r.doc_rev_id=c.doc_rev_id
    """

  func render(
    _ snapshot: DocRevision, archived: Bool, view: DocReadView, workspace workspaceID: Int64,
    in db: Database
  ) throws -> DocReadResult {
    let ref = "doc:\(snapshot.slug)@\(snapshot.revision)"
    switch view {
    case .body: return DocReadResult(ref: ref, output: body(snapshot, archived: archived))
    case .diff:
      let base: DocRevision?
      do {
        base = try snapshot.baseRevision.map {
          try DocStore.revision(snapshot.slug, revision: $0, workspace: workspaceID, in: db)
        }
      } catch DocError.notFound {
        throw CommandFailure(
          error: TaskError.notFound(
            "recorded base doc:\(snapshot.slug)@\(snapshot.baseRevision ?? 0)"),
          next: [showCommand(ref)])
      }
      return DocReadResult(ref: ref, output: DocDiff.render(snapshot, base: base))
    case .comments, .comment:
      guard
        let id = try Int64.fetchOne(
          db,
          sql:
            "SELECT id FROM doc_rev "
            + "WHERE doc_id=(SELECT id FROM doc WHERE workspace_id=? AND slug=?) AND rev=?",
          arguments: [workspaceID, snapshot.slug, snapshot.revision])
      else { throw StorageError.corrupt }
      return try comments(id, ref: ref, view: view, in: db)
    }
  }

  private func comments(_ id: Int64, ref: String, view: DocReadView, in db: Database) throws
    -> DocReadResult
  {
    let query = Self.commentQuery + " WHERE c.doc_rev_id=?"
    if case .comment(let seq) = view {
      guard let row = try Row.fetchOne(db, sql: query + " AND c.seq=?", arguments: [id, seq]) else {
        throw CommandFailure(
          error: TaskError.notFound("comment \(ref)/\(seq)"),
          next: [showCommand(ref) + " --comments"])
      }
      let post = CommentDetails(row: row, task: ref)
      return DocReadResult(ref: post.ref, output: DocComments.render(post))
    }
    guard case .comments(let offset, let limit) = view else { throw StorageError.internalMisuse }
    let total = try commentCount(id, in: db)
    let rows = try Row.fetchAll(
      db, sql: query + " ORDER BY c.seq LIMIT ? OFFSET ?", arguments: [id, limit, offset])
    var output =
      "\(ref) comments (offset \(offset), limit \(limit), total \(total))\n"
      + rows.map { DocComments.render(CommentDetails(row: $0, task: ref)) }.joined(separator: "\n")
    if offset < total && rows.count < total - offset {
      output +=
        "next: " + showCommand(ref)
        + " --comments --offset \(offset + rows.count) --limit \(limit)\n"
    }
    return DocReadResult(ref: ref, output: output)
  }

  func commentPreviews(_ id: Int64, ref: String, in db: Database) throws -> String {
    let total = try commentCount(id, in: db)
    guard total > 0 else { return "" }
    let rows = try Row.fetchAll(
      db, sql: Self.commentQuery + " WHERE c.doc_rev_id=? ORDER BY c.seq LIMIT 2", arguments: [id])
    return rows.map {
      let post = CommentDetails(row: $0, task: ref)
      return "  \(post.ref): \(Self.preview(post.body))\n"
    }.joined() + "  \(total) comments; \(total - rows.count) omitted; show: " + showCommand(ref)
      + " --comments --offset 0 --limit 20\n"
  }

  private func commentCount(_ id: Int64, in db: Database) throws -> Int {
    try Int.fetchOne(db, sql: "SELECT count(*) FROM comment WHERE doc_rev_id=?", arguments: [id])
      ?? 0
  }
}
