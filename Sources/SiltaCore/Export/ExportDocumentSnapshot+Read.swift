import GRDB

extension ExportDocumentSnapshot {
  /// Captures literal document truth inside the caller's consistent read transaction.
  static func read(_ db: Database, workspace: Int64) throws -> Self {
    var records: [Int64: [ExportRow]] = [:]
    for (format, sql) in zip(ExportFormat.docRecords, DocumentQuery.records) {
      for row in try Row.fetchAll(db, sql: sql, arguments: [workspace]) {
        records[row["doc_id"], default: []].append(try ExportRow(keys: format.keys, row: row))
      }
    }
    let documents = try Row.fetchAll(db, sql: DocumentQuery.documents, arguments: [workspace]).map {
      let row = try ExportRow(keys: ExportFormat.docKeys, row: $0)
      return ExportDocument(
        slug: row.value("slug") ?? "", row: row, records: records[$0["id"]] ?? [])
    }
    var snapshot = Self(documents: documents, revisionAllocations: [], commentSequences: [])
    var floors = try snapshot.minimumFloors()
    let prefix = "doc_rev:\(workspace):"
    for found in try Row.fetchAll(
      db, sql: "SELECT scope,next FROM seq_counter WHERE scope GLOB ?", arguments: [prefix + "*"])
    {
      let row = try ExportRow(keys: ["scope", "next"], row: found)
      let name = String((row.value("scope") ?? "").dropFirst(prefix.count))
      guard WorkspaceConfig.isValidIdentifier(name) else {
        throw ExportTree.invalid("a reserved document name is not an identifier")
      }
      floors.revisions[name] = max(
        floors.revisions[name] ?? 1, try Self.positive(row.value("next")))
    }
    for found in try Row.fetchAll(db, sql: DocumentQuery.commentFloors, arguments: [workspace]) {
      let row = try ExportRow(keys: ["doc_rev", "next"], row: found)
      let owner = row.value("doc_rev") ?? ""
      floors.comments[owner] = max(
        floors.comments[owner] ?? 1, try Self.positive(row.value("next")))
    }
    snapshot.revisionAllocations = Self.floorRows(floors.revisions, key: "slug")
    snapshot.commentSequences = Self.floorRows(floors.comments, key: "doc_rev")
    return snapshot
  }
}

private enum DocumentQuery {
  static let documents = """
    SELECT id,uid,slug,previous_slugs,title,kind,owner,current_rev,verified_at,archived,
      created_at,updated_at FROM doc WHERE workspace_id=? ORDER BY slug COLLATE BINARY
    """

  static let records = [
    """
    SELECT r.doc_id,'doc_rev' AS "table",r.uid,r.rev,r.base_rev,r.body_md,r.state,r.actor,
      r.message,r.created_at,r.title,r.kind,r.about_refs,t.uid AS source_task,
      r.triaged_at,r.triaged_by
    FROM doc_rev r JOIN doc d ON d.id=r.doc_id LEFT JOIN task t ON t.id=r.source_task_id
    WHERE d.workspace_id=? ORDER BY r.doc_id,r.rev
    """,
    """
    SELECT r.doc_id,'doc_verification' AS "table",v.uid,r.uid AS doc_rev,v.actor,v.message,
      v.app_shas,v.created_at
    FROM doc_verification v JOIN doc_rev r ON r.id=v.doc_rev_id JOIN doc d ON d.id=r.doc_id
    WHERE d.workspace_id=? ORDER BY v.id
    """,
    """
    SELECT r.doc_id,'comment' AS "table",c.uid,r.uid AS doc_rev,c.seq,root.uid AS thread,
      c.kind,c.verdict,c.subject,c.anchor,c.anchor_sha,c.anchor_snippet,c.body_md,c.mentions,
      c.accepted,c.actor,c.resolved_at,c.resolved_by,c.deleted_at,c.created_at
    FROM comment c JOIN doc_rev r ON r.id=c.doc_rev_id JOIN doc d ON d.id=r.doc_id
      LEFT JOIN comment root ON root.id=c.thread_id
    WHERE d.workspace_id=? ORDER BY c.id
    """,
  ]

  static let commentFloors = """
    SELECT r.uid AS doc_rev,c.next
    FROM seq_counter c JOIN doc_rev r ON c.scope='comment:doc_rev:'||r.id
      JOIN doc d ON d.id=r.doc_id
    WHERE d.workspace_id=?
    """
}
