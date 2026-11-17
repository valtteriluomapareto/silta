import Foundation
import GRDB

struct DocProposalInbox {
  let workspace: String
  let workspaceID: Int64
  let at: Date
  let all: Bool
  let db: Database

  init(workspace: String, at: Date, all: Bool = false, in db: Database) throws {
    self.workspace = workspace
    workspaceID = try TaskService.workspaceID(workspace, in: db)
    self.at = at
    self.all = all
    self.db = db
  }

  var eligibility: String {
    "d.workspace_id=? AND (? OR d.archived=0) AND r.state='proposed' AND (? OR r.created_at>?)"
  }

  var arguments: StatementArguments {
    [workspaceID, all, all, utcTimestamp(at.addingTimeInterval(-14 * 86400))]
  }

  func count() throws -> Int {
    try Int.fetchOne(
      db,
      sql: """
        SELECT count(*) FROM (SELECT d.uid FROM doc d JOIN doc_rev r ON r.doc_id=d.id
        WHERE \(eligibility) GROUP BY d.uid COLLATE BINARY)
        """, arguments: arguments) ?? 0
  }

  func groups(limit: Int? = nil) throws -> [DocProposalGroup] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT d.id,count(*) AS total,max(r.created_at) AS newest
        FROM doc d JOIN doc_rev r ON r.doc_id=d.id WHERE \(eligibility)
        GROUP BY d.uid COLLATE BINARY ORDER BY newest DESC,d.uid COLLATE BINARY LIMIT ?
        """, arguments: arguments + [limit ?? -1]
    ).map {
      DocProposalGroup(id: $0["id"], total: $0["total"], newestAt: $0["newest"])
    }
  }

  func previews(_ groups: [DocProposalGroup], caller: ActorID) throws -> [DocProposalPreviewGroup] {
    guard !groups.isEmpty else { return [] }
    let columns = try db.columns(in: "doc_rev").map(\.name)
    let metadata = columns.contains("source_task_id")
    let targets = columns.contains("about_targets")
    let selected = try Row.fetchAll(
      db, sql: memberSQL(metadata: metadata, targets: targets),
      arguments: arguments + [try WorkspaceConfig.json(groups.map(\.id))])
    let rows = Dictionary(grouping: selected) { $0["doc_id"] as Int64 }
    return try groups.map { group in
      guard let members = rows[group.id], let first = members.first else {
        throw StorageError.corrupt
      }
      let previews = try members.map { try member($0, caller: caller) }
      return DocProposalPreviewGroup(
        id: group.id, ref: try text(first, "doc_ref", reference: true), total: group.total,
        members: previews,
        next: group.total > previews.count ? try page(value(first, "slug")) : nil)
    }
  }

  private func memberSQL(metadata: Bool, targets: Bool) -> String {
    let title = metadata ? "r.title" : "NULL"
    let kind = metadata ? "r.kind" : "NULL"
    let about = metadata ? "r.about_refs" : "NULL"
    let source = metadata ? "r.source_task_id" : "NULL"
    let fields = [
      "d.id AS doc_id,r.rev,r.base_rev,r.base_rev IS NOT d.current_rev AS stale_base,"
        + "b.id AS base_id,\(source) AS source_id,s.id AS source_owner",
      Self.bounded("'doc:'||d.slug", "doc_ref"),
      Self.bounded("'doc:'||d.slug||'@'||r.rev", "ref"),
      "CASE WHEN length(CAST(d.slug AS BLOB))<=512 THEN CAST(d.slug AS BLOB) END AS slug",
      Self.bounded(title, "title"), Self.bounded(kind, "kind"), Self.bounded("r.message", "why"),
      Self.bounded("w.task_prefix||'-'||s.seq", "source"),
      "length(CAST(r.body_md AS BLOB)) AS new_bytes",
      "coalesce(length(CAST(b.body_md AS BLOB)),0) AS old_bytes",
      """
      CASE WHEN r.base_rev IS NULL THEN length(CAST(r.body_md AS BLOB))=0
        ELSE CAST(r.body_md AS BLOB) IS CAST(b.body_md AS BLOB) END AS body_equal
      """,
      Self.change(title, metadata ? "b.title" : "NULL", "title"),
      Self.change(kind, metadata ? "b.kind" : "NULL", "kind"),
      Self.aboutChange(about, metadata ? "b.about_refs" : "NULL", targets: targets),
    ].joined(separator: ",\n")
    return """
      WITH eligible AS (
        SELECT r.id,ROW_NUMBER() OVER(PARTITION BY r.doc_id
          ORDER BY r.created_at DESC,r.rev DESC,r.uid COLLATE BINARY) AS position
        FROM doc_rev r JOIN doc d ON d.id=r.doc_id
        WHERE \(eligibility) AND d.id IN (SELECT value FROM json_each(?))
      )
      SELECT \(fields) FROM eligible e JOIN doc_rev r ON r.id=e.id JOIN doc d ON d.id=r.doc_id
      LEFT JOIN doc_rev b ON b.doc_id=d.id AND b.rev=r.base_rev
      LEFT JOIN task s ON s.id=\(source) AND s.workspace_id=d.workspace_id
      LEFT JOIN workspace w ON w.id=s.workspace_id
      WHERE e.position<=2 ORDER BY d.id,e.position
      """
  }

  private static func aboutChange(_ value: String, _ base: String, targets: Bool) -> String {
    guard targets else { return change(value, base, "about") }
    return """
      CASE WHEN \(value) IS NULL OR \(base) IS NULL THEN NULL
      ELSE CAST(\(value) AS BLOB) IS NOT CAST(\(base) AS BLOB)
        OR (r.about_targets IS NOT NULL AND b.about_targets IS NOT NULL AND (
          EXISTS(SELECT json_extract(value,'$.kind'),json_extract(value,'$.uid')
            FROM json_each(r.about_targets)
            EXCEPT SELECT json_extract(value,'$.kind'),json_extract(value,'$.uid')
            FROM json_each(b.about_targets))
          OR EXISTS(SELECT json_extract(value,'$.kind'),json_extract(value,'$.uid')
            FROM json_each(b.about_targets)
            EXCEPT SELECT json_extract(value,'$.kind'),json_extract(value,'$.uid')
            FROM json_each(r.about_targets))
        )) END AS about_change
      """
  }

  private static func bounded(_ expression: String, _ name: String) -> String {
    "CASE WHEN length(CAST(\(expression) AS BLOB))<=65536 THEN CAST(\(expression) AS BLOB) END AS \(name),"
      + "length(CAST(\(expression) AS BLOB)) AS \(name)_bytes"
  }

  private static func change(_ value: String, _ base: String, _ name: String) -> String {
    "CASE WHEN \(value) IS NULL OR \(base) IS NULL THEN NULL "
      + "ELSE CAST(\(value) AS BLOB) IS NOT CAST(\(base) AS BLOB) END AS \(name)_change"
  }
}
