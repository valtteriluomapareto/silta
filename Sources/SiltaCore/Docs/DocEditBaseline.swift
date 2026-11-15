import Foundation
import GRDB

/// Exact owned state used to preserve content or exempt it from a new-content scan.
struct DocEditBaseline: Equatable {
  let literalFields: [Data]
  let identities: [String?]
  let archived: Bool
  let rowRevision: Int?
  let state: String?
  let documentExists: Bool
  let accepted: Bool
  let body: String?
  let title: String?
  let kind: String?
  let revision: Int?
  let refs: [String]

  static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.literalFields == rhs.literalFields, lhs.identities == rhs.identities,
      lhs.archived == rhs.archived, lhs.rowRevision == rhs.rowRevision, lhs.state == rhs.state,
      lhs.documentExists == rhs.documentExists, lhs.accepted == rhs.accepted,
      lhs.revision == rhs.revision, lhs.title == rhs.title, lhs.kind == rhs.kind,
      lhs.refs == rhs.refs
    else { return false }
    switch (lhs.body, rhs.body) {
    case (nil, nil): return true
    case (let left?, let right?): return left.utf8.elementsEqual(right.utf8)
    default: return false
    }
  }

  static func read(_ slug: String, workspace: Int64, keepBody: Bool, in db: Database) throws -> Self
  {
    let workspaceUID = try StoredUID.fetch(
      db, sql: "SELECT uid FROM workspace WHERE id=?", arguments: [workspace])
    let cursor = try Row.fetchCursor(
      db,
      sql: """
        SELECT d.id,d.uid,d.current_rev,d.archived,d.title,d.kind,r.uid AS revision_uid,
          r.rev,r.state,CASE WHEN ? OR length(CAST(r.body_md AS BLOB))<=?
            THEN CAST(r.body_md AS BLOB) END AS body
        FROM doc d LEFT JOIN doc_rev r ON r.doc_id=d.id AND r.rev=d.current_rev
        WHERE d.workspace_id=? AND d.slug=?
        """, arguments: [keepBody, DocInput.maximumBytes, workspace, slug])
    defer { withExtendedLifetime(cursor) {} }
    guard let row = try cursor.next() else {
      return Self(
        literalFields: [], identities: [workspaceUID], archived: false, rowRevision: nil,
        state: nil, documentExists: false, accepted: false, body: nil, title: nil, kind: nil,
        revision: nil, refs: [])
    }
    let pointer: Int? = row["current_rev"]
    let revision: Int? = row["rev"]
    let archived: Bool = row["archived"]
    let bodyBytes: Data? = row["body"]
    let body = try bodyBytes.map { bytes in
      guard let text = String(data: bytes, encoding: .utf8) else { throw StorageError.corrupt }
      return text
    }
    let state: String? = row["state"]
    let title: String = row["title"]
    let kind: String = row["kind"]
    var literalFields: [Data] = [Data(title.utf8), Data(kind.utf8)]
    var identities = [
      workspaceUID, try StoredUID.read(from: row), try StoredUID.read("revision_uid", from: row),
    ]
    var refs: [String] = []
    for link in try DocStore.attachments(row["id"], workspace: workspace, in: db) {
      let ref = try TaskLinkTarget.render(link, in: db)
      let target = try TaskLinkTarget.map(ref, workspace: workspace, in: db)
      let uid = try StoredUID.fetch(
        db, sql: "SELECT uid FROM \(target.kind) WHERE id=?", arguments: [target.id])
      literalFields.append(Data(ref.utf8))
      identities.append(uid)
      refs.append(ref)
    }
    return Self(
      literalFields: literalFields, identities: identities, archived: archived,
      rowRevision: revision, state: state, documentExists: true, accepted: state == "accepted",
      body: body, title: title, kind: kind, revision: pointer, refs: refs)
  }
}
