import Foundation
import GRDB

/// Exact owned state used to preserve content or exempt it from a new-content scan.
struct DocEditBaseline: Equatable {
  let literalFields: [Data]
  let identities: [String?]
  let archived: Bool
  let state: String?
  let accepted: Bool
  let body: String?
  let title: String?
  let kind: String?
  let revision: Int?
  let refs: [String]

  static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.literalFields == rhs.literalFields, lhs.identities == rhs.identities,
      lhs.archived == rhs.archived, lhs.state == rhs.state, lhs.revision == rhs.revision
    else { return false }
    switch (lhs.body, rhs.body) {
    case (nil, nil): return true
    case (let left?, let right?): return left.utf8.elementsEqual(right.utf8)
    default: return false
    }
  }

  static func read(_ slug: String, workspace: Int64, keepBody: Bool, in db: Database) throws -> Self
  {
    let workspaceUID = try String.fetchOne(
      db, sql: "SELECT uid FROM workspace WHERE id=?", arguments: [workspace])
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT d.id,d.uid,d.current_rev,d.archived,CAST(d.title AS BLOB) AS title,
            CAST(d.kind AS BLOB) AS kind,r.uid AS revision_uid,
            r.state,CASE WHEN ? OR length(CAST(r.body_md AS BLOB))<=?
              THEN CAST(r.body_md AS BLOB) END AS body
          FROM doc d LEFT JOIN doc_rev r ON r.doc_id=d.id AND r.rev=d.current_rev
          WHERE d.workspace_id=? AND d.slug=?
          """, arguments: [keepBody, BoundedInput.maximumBodyBytes, workspace, slug])
    else {
      return Self(
        literalFields: [], identities: [workspaceUID], archived: false,
        state: nil, accepted: false, body: nil, title: nil, kind: nil,
        revision: nil, refs: [])
    }
    let pointer: Int? = row["current_rev"]
    let archived: Bool = row["archived"]
    let bodyBytes: Data? = row["body"]
    let body = try bodyBytes.map(text)
    let state: String? = row["state"]
    let titleBytes: Data = row["title"]
    let kindBytes: Data = row["kind"]
    let title = try text(titleBytes)
    let kind = try text(kindBytes)
    var literalFields = [titleBytes, kindBytes]
    var identities = [
      workspaceUID, (row["uid"] as String?), (row["revision_uid"] as String?),
    ]
    var refs: [String] = []
    for link in try DocStore.attachments(row["id"], workspace: workspace, in: db) {
      let ref = try TaskLinkTarget.render(link, in: db)
      let target = try TaskLinkTarget.map(ref, workspace: workspace, in: db)
      let uid = try String.fetchOne(
        db, sql: "SELECT uid FROM \(target.kind) WHERE id=?", arguments: [target.id])
      literalFields.append(Data(ref.utf8))
      identities.append(uid)
      refs.append(ref)
    }
    return Self(
      literalFields: literalFields, identities: identities, archived: archived,
      state: state, accepted: state == "accepted",
      body: body, title: title, kind: kind, revision: pointer, refs: refs)
  }

  private static func text(_ bytes: Data) throws -> String {
    guard let value = String(data: bytes, encoding: .utf8) else { throw StorageError.corrupt }
    return value
  }

}
