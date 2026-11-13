import Foundation
import GRDB

extension DocService {
  func read(_ slug: String, revision: Int?) throws
    -> DocReadSelection
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
        return DocReadSelection(
          revision: try DocStore.revision(slug, revision: selected, workspace: workspaceID, in: db),
          archived: archived, pending: [], pendingCount: 0)
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
      return DocReadSelection(
        revision: nil, archived: archived, pending: pending, pendingCount: total)
    }
  }

  /// Lists accepted live attachments and proposed snapshots as separate pageable entries.
  package func list(about: String? = nil, archived: Bool = false, offset: Int = 0, limit: Int = 20)
    throws -> DocListResult
  {
    guard offset >= 0, (1...100).contains(limit) else {
      throw UsageError.usage(
        message: "Use --offset >= 0 and --limit from 1 to 100.", command: "silta doc ls")
    }
    return try store.read { db in
      let workspaceID = try TaskService.workspaceID(workspace, in: db)
      var predicate =
        "doc.workspace_id=? AND (? OR doc.archived=0)"
        + " AND ((doc_rev.rev=doc.current_rev AND doc_rev.state='accepted')"
        + " OR doc_rev.state='proposed')"
      var arguments: StatementArguments = [workspaceID, archived]
      if let about {
        let target = try attachment(about, workspace: workspaceID, in: db)
        predicate += """
           AND (EXISTS(SELECT 1 FROM link WHERE link.workspace_id=doc.workspace_id
             AND from_kind='doc' AND from_id=doc.id AND rel='about' AND to_kind=? AND to_id=?)
             OR (doc_rev.state='proposed' AND EXISTS(
               SELECT 1 FROM json_each(doc_rev.about_refs) WHERE value=?)))
          """
        arguments += [target.kind, target.id, about]
      }
      let join = " FROM doc JOIN doc_rev ON doc_rev.doc_id=doc.id WHERE " + predicate
      let total = try Int.fetchOne(db, sql: "SELECT count(*)" + join, arguments: arguments) ?? 0
      let rows = try Row.fetchAll(
        db,
        sql:
          "SELECT doc.slug,doc_rev.rev,doc_rev.state,doc_rev.title,doc_rev.kind,doc_rev.about_refs"
          + join + " ORDER BY doc.slug,doc_rev.rev LIMIT ? OFFSET ?",
        arguments: arguments + [limit, offset])
      let entries = try rows.map(entry)
      var command = listCommand
      if let about { command += " --about " + shellWord(about) }
      if archived { command += " --archived" }
      let continuation =
        about.map { !Self.safeReference($0) } == true
        ? listCommand : command + " --offset \(offset + entries.count) --limit \(limit)"
      let next = offset < total && entries.count < total - offset ? continuation : nil
      return DocListResult(entries: entries, total: total, offset: offset, limit: limit, next: next)
    }
  }

  private func attachment(_ ref: String, workspace workspaceID: Int64, in db: Database) throws
    -> TaskLinkTarget
  {
    do {
      return try TaskLinkTarget.map(ref, workspace: workspaceID, in: db)
    } catch let error as any CodedError where error.code == .notFound && !Self.safeReference(ref) {
      throw CommandFailure(
        error: TaskError.notFound("attachment " + (ref.removingPercentEncoding ?? ref)),
        next: [workspaceCommand("silta ws show", workspace: workspace)])
    }
  }

  private func entry(_ row: Row) throws -> DocListResult.Entry {
    let ref = "doc:\(row["slug"] as String)@\(row["rev"] as Int)"
    let state: String = row["state"]
    let raw: String? = row["about_refs"]
    let refs: [String]?
    do {
      refs = try raw.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    } catch { throw StorageError.corrupt }
    let title: String? = row["title"]
    let kind: String? = row["kind"]
    return DocListResult.Entry(
      ref: ref, state: state,
      output: "\(ref) [\(state)] \(Self.preview(title ?? "(unknown)"))\n"
        + "  kind: \(Self.preview(kind ?? "(unknown)")); about: \(Self.preview(Self.about(refs)))\n"
        + "  show: " + showCommand(ref) + "\n")
  }

}
