import Foundation
import GRDB

extension ExportDocumentSnapshot {
  /// Captures literal document truth inside the caller's consistent read transaction.
  static func read(_ db: Database, workspace: Int64) throws -> Self {
    var records: [Int64: [ExportRow]] = [:]
    let targets = try db.columns(in: "doc_rev").contains { $0.name == "about_targets" }
    for (format, sql) in zip(ExportFormat.docRecords, DocumentQuery.records(targets: targets)) {
      let cursor = try Row.fetchCursor(db, sql: sql, arguments: [workspace])
      while let row = try cursor.next() {
        let keys = format.table == "doc_rev" ? format.keys.filter { $0 != "body_md" } : format.keys
        var record = try ExportRow(keys: keys, row: row)
        if format.table == "doc_rev" {
          guard let bytes: Data = row["body_md"], let body = String(data: bytes, encoding: .utf8)
          else { throw StorageError.corrupt }
          record = record.replacing("body_md", with: body, keys: format.keys)
        }
        records[row["doc_id"], default: []].append(record)
      }
    }
    let documents = try Array(
      Row.fetchCursor(db, sql: DocumentQuery.documents, arguments: [workspace]).map {
        let row = try ExportRow(keys: ExportFormat.docKeys, row: $0)
        return ExportDocument(
          slug: row.value("slug") ?? "", row: row, records: records[$0["id"]] ?? [])
      })
    var snapshot = Self(documents: documents, revisionAllocations: [])
    var floors = try snapshot.minimumRevisionFloors()
    let prefix = "doc_rev:\(workspace):"
    let counters = try Row.fetchCursor(
      db, sql: "SELECT scope,next FROM seq_counter WHERE scope GLOB ?", arguments: [prefix + "*"])
    while let found = try counters.next() {
      let row = try ExportRow(keys: ["scope", "next"], row: found)
      let name = String((row.value("scope") ?? "").dropFirst(prefix.count))
      guard WorkspaceConfig.isValidIdentifier(name) else {
        throw ExportTree.invalid("a reserved document name is not an identifier")
      }
      floors[name] = max(
        floors[name] ?? 1, try Self.positive(row.value("next")))
    }
    snapshot.revisionAllocations = Self.floorRows(floors, key: "slug")
    return snapshot
  }
}

private enum DocumentQuery {
  static let documents = """
    SELECT id,uid,slug,previous_slugs,title,kind,owner,current_rev,verified_at,archived,
      created_at,updated_at FROM doc WHERE workspace_id=? ORDER BY slug COLLATE BINARY
    """

  static func records(targets: Bool) -> [String] {
    [
      """
      SELECT r.doc_id,'doc_rev' AS "table",r.uid,r.rev,r.base_rev,
        CAST(r.body_md AS BLOB) AS body_md,r.state,r.actor,r.message,r.created_at,
        r.title,r.kind,r.about_refs,\(targets ? "r.about_targets" : "NULL AS about_targets"),t.uid AS source_task,
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

  }

}
