import GRDB

/// Exact owned state used to preserve content or exempt it from a new-content scan.
struct DocEditBaseline {
  let fields: [String?]
  let documentExists: Bool
  let accepted: Bool
  let body: String?
  let title: String?
  let refs: [String]

  static func read(_ slug: String, workspace: Int64, keepBody: Bool, in db: Database) throws -> Self
  {
    let workspaceUID = try String.fetchOne(
      db, sql: "SELECT uid FROM workspace WHERE id=?",
      arguments: [workspace])
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT d.id,d.uid,d.current_rev,d.archived,d.title,d.kind,r.uid AS revision_uid,
          r.rev,r.state,CASE WHEN ? OR length(CAST(r.body_md AS BLOB))<=? THEN r.body_md END AS body
        FROM doc d LEFT JOIN doc_rev r ON r.doc_id=d.id AND r.rev=d.current_rev
        WHERE d.workspace_id=? AND d.slug=?
        """, arguments: [keepBody, DocInput.maximumBytes, workspace, slug])
    guard let row else {
      return Self(
        fields: [workspaceUID], documentExists: false, accepted: false, body: nil, title: nil,
        refs: [])
    }
    let pointer: Int? = row["current_rev"]
    let revision: Int? = row["rev"]
    let archived: Bool = row["archived"]
    let body: String? = row["body"]
    let state: String? = row["state"]
    let title: String = row["title"]
    var fields: [String?] = [
      workspaceUID, row["uid"], pointer.map(String.init),
      archived ? "1" : "0", title, row["kind"], row["revision_uid"], revision.map(String.init),
      row["state"], body,
    ]
    var refs: [String] = []
    for link in try DocStore.attachments(row["id"], workspace: workspace, in: db) {
      let ref = try TaskLinkTarget.render(link, in: db)
      let target = try TaskLinkTarget.map(ref, workspace: workspace, in: db)
      let uid = try String.fetchOne(
        db, sql: "SELECT uid FROM \(target.kind) WHERE id=?",
        arguments: [target.id])
      fields += [ref, uid]
      refs.append(ref)
    }
    return Self(
      fields: fields, documentExists: true, accepted: state == "accepted",
      body: body, title: title, refs: refs)
  }

  func matches(_ other: Self) -> Bool {
    documentExists == other.documentExists
      && fields.elementsEqual(other.fields) { left, right in
        switch (left, right) {
        case (nil, nil): true
        case (let left?, let right?): left.utf8.elementsEqual(right.utf8)
        default: false
        }
      }
  }
}
