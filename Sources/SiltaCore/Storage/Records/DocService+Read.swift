import Foundation
import GRDB

extension DocService {
  func read(_ slug: String, revision: Int?, view: DocReadView) throws
    -> DocReadResult
  {
    try store.read { db in
      let workspaceID = try TaskService.workspaceID(workspace, in: db)
      guard
        let doc = try Row.fetchOne(
          db, sql: "SELECT id,current_rev,archived FROM doc WHERE workspace_id=? AND slug=?",
          arguments: [workspaceID, slug])
      else { throw DocError.notFound(slug) }
      let archived: Bool = doc["archived"]
      if let selected = revision ?? (doc["current_rev"] as Int?) {
        let snapshot = try DocStore.revision(
          slug, revision: selected, workspace: workspaceID, in: db)
        if revision == nil, case .body = view {
          let pending =
            try Int.fetchOne(
              db, sql: "SELECT count(*) FROM doc_rev WHERE doc_id=? AND state='proposed'",
              arguments: [doc["id"]]) ?? 0
          return body(snapshot, archived: archived, pending: pending)
        }
        return try render(
          snapshot, archived: archived, view: view, workspace: workspaceID, in: db
        )
      }
      let id: Int64 = doc["id"]
      let total =
        try Int.fetchOne(
          db, sql: "SELECT count(*) FROM doc_rev WHERE doc_id=? AND state='proposed'",
          arguments: [id]) ?? 0
      let pending = try Int.fetchAll(
        db,
        sql: "SELECT rev FROM doc_rev WHERE doc_id=? AND state='proposed' ORDER BY rev LIMIT 20",
        arguments: [id])
      return DocReadResult(
        ref: "doc:" + slug,
        output: "No accepted revision for doc:\(slug).\nPending revisions (\(total)):\n"
          + pending.map { "doc:\(slug)@\($0)\n" }.joined()
          + (total > pending.count && scopeIsSafe && Self.safeReference("doc:" + slug)
            ? "next: "
              + listPageCommand(
                about: nil, archived: archived, offset: 0, limit: 20, document: slug) + "\n" : ""))
    }
  }

  /// Lists accepted live attachments and proposed snapshots as separate pageable entries.
  package func list(
    about: String? = nil, archived: Bool = false, offset: Int = 0, limit: Int = 20,
    document: String? = nil
  )
    throws -> DocListResult
  {
    guard offset >= 0, (1...100).contains(limit) else {
      throw UsageError.usage(
        message: "Use --offset >= 0 and --limit from 1 to 100.", command: "silta doc ls")
    }
    let document = try Self.documentFilter(document)
    return try store.read { db in
      let workspaceID = try TaskService.workspaceID(workspace, in: db)
      let available = try db.columns(in: "doc_rev").map(\.name)
      let metadata = available.contains("about_refs")
      let snapshotTargets = available.contains("about_targets") ? "doc_rev.about_targets" : "NULL"
      let columns = ["title", "kind", "about_refs"].map {
        metadata ? "CAST(doc_rev.\($0) AS BLOB) AS \($0)" : "NULL AS \($0)"
      }.joined(separator: ",")
      var predicate =
        "doc.workspace_id=? AND (? OR doc.archived=0)"
        + " AND ((doc_rev.rev=doc.current_rev AND doc_rev.state='accepted')"
        + " OR doc_rev.state='proposed')"
      var arguments: StatementArguments = [workspaceID, archived]
      if let document {
        predicate += " AND doc.slug=?"
        arguments += [document]
      }
      let target = try about.map { try attachment($0, workspace: workspaceID, in: db) }
      if let target {
        let filter = try listAttachmentFilter(target, snapshots: snapshotTargets, in: db)
        predicate += filter.sql
        arguments += filter.arguments
      }
      let join = " FROM doc JOIN doc_rev ON doc_rev.doc_id=doc.id WHERE " + predicate
      let total = try Int.fetchOne(db, sql: "SELECT count(*)" + join, arguments: arguments) ?? 0
      let rows = try Row.fetchAll(
        db,
        sql:
          "SELECT CAST(doc.slug AS BLOB) AS slug,doc_rev.id,doc_rev.rev,doc_rev.state,doc.archived,"
          + columns + "," + attributionColumns(available)
          + join + " ORDER BY doc.slug,doc_rev.rev LIMIT ? OFFSET ?",
        arguments: arguments + [limit, offset])
      let entries = try rows.map { try entry($0, in: db) }
      let next =
        offset < total && entries.count < total - offset
        ? listPageCommand(
          about: try target.map { try $0.rendered(in: db) }, archived: archived,
          offset: offset + entries.count, limit: limit, document: document)
        : nil
      return DocListResult(
        entries: entries, total: total, offset: offset, limit: limit, next: next,
        warnings: target?.warnings ?? [])
    }
  }

  /// Pages all stored states of one document, including superseded revisions.
  package func revisions(_ ref: String, offset: Int = 0, limit: Int = 20) throws -> DocListResult {
    guard offset >= 0, (1...100).contains(limit) else {
      throw DocError.invalid("Use a nonnegative offset and a limit from 1 to 100.")
    }
    let slug = try Self.selection(ref, revision: nil).slug
    return try store.read { db in
      let workspaceID = try TaskService.workspaceID(workspace, in: db)
      let columns = try db.columns(in: "doc_rev").map(\.name)
      let metadata = ["title", "kind", "about_refs"].map {
        columns.contains($0) ? "CAST(doc_rev.\($0) AS BLOB) AS \($0)" : "NULL AS \($0)"
      }.joined(separator: ",")
      let join =
        " FROM doc JOIN doc_rev ON doc_rev.doc_id=doc.id WHERE doc.workspace_id=? AND doc.slug=?"
      let args: StatementArguments = [workspaceID, slug]
      let total = try Int.fetchOne(db, sql: "SELECT count(*)" + join, arguments: args) ?? 0
      let rows = try Row.fetchAll(
        db,
        sql:
          "SELECT CAST(doc.slug AS BLOB) AS slug,doc_rev.id,doc_rev.rev,doc_rev.state,doc.archived,"
          + metadata + "," + attributionColumns(columns) + join
          + " ORDER BY doc_rev.rev DESC LIMIT ? OFFSET ?",
        arguments: args + [limit, offset])
      return DocListResult(
        entries: try rows.map { try entry($0, in: db) }, total: total,
        offset: offset, limit: limit, next: nil)
    }
  }

  private func listAttachmentFilter(_ target: TaskLinkTarget, snapshots: String, in db: Database)
    throws
    -> (sql: String, arguments: StatementArguments)
  {
    guard let targetID = target.id,
      let uid = try String.fetchOne(
        db, sql: "SELECT uid FROM \(target.kind) WHERE id=?", arguments: [targetID])
    else { throw StorageError.corrupt }
    return (
      """
       AND ((doc_rev.state='accepted' AND EXISTS(SELECT 1 FROM link
         WHERE link.workspace_id=doc.workspace_id
         AND from_kind='doc' AND from_id=doc.id AND rel='about' AND to_kind=? AND to_id=?))
         OR (doc_rev.state='proposed' AND EXISTS(
           SELECT 1 FROM json_each(\(snapshots)) WHERE json_extract(value,'$.kind')=?
           AND json_extract(value,'$.uid')=?)))
      """,
      [target.kind, targetID, target.kind, uid]
    )
  }

  private func attachment(_ ref: String, workspace workspaceID: Int64, in db: Database) throws
    -> TaskLinkTarget
  {
    do {
      return try TaskLinkTarget.map(ref, workspace: workspaceID, in: db)
    } catch let error as any CodedError {
      if error.code == .notFound && !Self.safeReference(ref) {
        throw CommandFailure(
          error: TaskError.notFound("attachment " + (ref.removingPercentEncoding ?? ref)),
          next: [configurationCommand])
      }
      if !scopeIsSafe { throw CommandFailure(error: error, next: [configurationCommand]) }
      throw error
    }
  }

  private func attributionColumns(_ available: [String]) -> String {
    let fields = [
      ("actor", "actor"), ("created_at", "createdAt"), ("message", "message"),
      ("triaged_by", "triagedBy"), ("triaged_at", "triagedAt"),
    ]
    let columns = fields.map { column, alias in
      available.contains(column)
        ? "CAST(doc_rev.\(column) AS BLOB) AS \(alias)" : "NULL AS \(alias)"
    }
    let source =
      available.contains("source_task_id")
      ? """
      CAST((SELECT workspace.task_prefix||'-'||task.seq FROM task
      JOIN workspace ON workspace.id=task.workspace_id
      WHERE task.id=doc_rev.source_task_id AND task.workspace_id=doc.workspace_id) AS BLOB)
      """ : "NULL"
    return (columns + [source + " AS sourceTask"]).joined(separator: ",")
  }

  private func entry(_ row: Row, in db: Database) throws -> DocListResult.Entry {
    guard let slug = try row.strictText("slug") else { throw StorageError.corrupt }
    let ref = "doc:\(slug)@\(row["rev"] as Int)"
    let state: String = row["state"]
    let raw = try row.strictText("about_refs")
    let refs: [String]?
    do {
      refs = try raw.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    } catch { throw StorageError.corrupt }
    let title = try row.strictText("title")
    let kind = try row.strictText("kind")
    let metadata = DocDisplayMetadata(
      ref: ref, slug: slug, revision: row["rev"], title: title,
      kind: kind, about: refs, state: state, archived: row["archived"],
      actor: try row.strictText("actor"), createdAt: try row.strictText("createdAt"),
      sourceTask: try row.strictText("sourceTask"), message: try row.strictText("message"),
      triagedBy: try row.strictText("triagedBy"), triagedAt: try row.strictText("triagedAt")
    ).masked
    let rendered = DocReadResult(
      masking: ref,
      output: "\(ref) [\(state)] \(metadata.title ?? "(unknown)")\n"
        + "  kind: \(metadata.kind ?? "(unknown)"); about: \(Self.preview(Self.about(refs)))\n"
        + "  show: " + showCommand(ref) + "\n"
        + (try commentPreviews(row["id"], ref: ref, in: db)))
    return DocListResult.Entry(
      ref: rendered.ref, state: state, output: rendered.output, metadata: metadata)
  }

}
