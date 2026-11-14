import Foundation
import GRDB

extension DocProposalService {
  func binding(
    _ metadata: DocMetadata, base: Int?, request: DocProposalRequest, id: Int64, in db: Database
  ) throws -> [String?] {
    var fields: [String?] = []
    if let base {
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT r.id,r.uid,r.state FROM doc_rev r JOIN doc d ON d.id=r.doc_id
            WHERE d.workspace_id=? AND d.slug=? AND r.rev=?
            """, arguments: [id, request.slug, base])
      else { throw DocError.notFound(request.slug + "@\(base)") }
      guard row["state"] as String == "accepted" else {
        throw DocError.invalid("--base must name an accepted revision of this doc.")
      }
      fields += [String(row["id"] as Int64), row["uid"], row["state"]]
    }
    for ref in metadata.refs {
      let target = try TaskLinkTarget.map(ref, workspace: id, in: db)
      guard let targetID = target.id,
        let uid = try String.fetchOne(
          db, sql: "SELECT uid FROM \(target.kind) WHERE id=?", arguments: [targetID])
      else { throw StorageError.corrupt }
      fields += [ref, target.kind, String(targetID), uid]
    }
    return fields
  }

  func source(
    _ request: DocProposalRequest, workspace: String, id: Int64, at: Date, in db: Database
  ) throws -> (id: Int64?, fields: [String?]) {
    if let ref = request.task {
      let task = try TaskService.lookup(ref, workspace: workspace, in: db)
      guard
        let uid = try String.fetchOne(
          db, sql: "SELECT uid FROM task WHERE id=?", arguments: [task.id])
      else { throw StorageError.corrupt }
      return (task.id, [String(task.id), String(task.workspaceID), uid])
    }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id,uid,status,claimed_by,claimed_at FROM task
        WHERE workspace_id=? AND claimed_by=? AND status='doing' AND claimed_at>?
        ORDER BY id
        """,
      arguments: [
        id, environment.actor.description,
        utcTimestamp(at.addingTimeInterval(-TaskService.claimDuration)),
      ])
    guard rows.count <= 1 else { throw DocError.missing(["--task"]) }
    guard let row = rows.first else { return (nil, []) }
    let source: Int64 = row["id"]
    return (
      source, [String(source), row["uid"], row["status"], row["claimed_by"], row["claimed_at"]]
    )
  }
}
