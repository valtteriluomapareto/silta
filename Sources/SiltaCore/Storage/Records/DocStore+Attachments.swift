import GRDB

extension DocStore {
  func attachments(_ doc: Int64) throws -> [Row] {
    try Self.attachments(doc, workspace: workspace, in: db)
  }

  static func attachments(_ doc: Int64, workspace: Int64, in db: Database) throws -> [Row] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT id,to_kind,to_id,to_ext,anchor FROM link
        WHERE workspace_id=? AND from_kind='doc' AND from_id=? AND rel='about' ORDER BY id
        """, arguments: [workspace, doc])
  }

  func replaceAttachments(_ targets: [TaskLinkTarget], doc: Int64, stamp: String) throws {
    let desired = Set(try targets.map(Self.key))
    var kept: Set<String> = []
    for link in try attachments(doc) {
      let kind: String = link["to_kind"]
      let id: Int64? = link["to_id"]
      let anchor: String? = link["anchor"]
      let external: String? = link["to_ext"]
      if let id, anchor == nil, external == nil, desired.contains(kind + ":\(id)") {
        kept.insert(kind + ":\(id)")
      } else {
        try db.execute(sql: "DELETE FROM link WHERE id=?", arguments: [link["id"]])
      }
    }
    for target in targets where !(kept.contains(try Self.key(target))) {
      try db.execute(
        sql: """
          INSERT INTO link(
            uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
          VALUES(?,?,'doc',?,'about',?,?,?,?)
          """,
        arguments: [
          try ids.next(at: at), workspace, doc, target.kind,
          target.id, actor.description, stamp,
        ])
    }
  }

  private static func key(_ target: TaskLinkTarget) throws -> String {
    guard let id = target.id else { throw StorageError.internalMisuse }
    return target.kind + ":\(id)"
  }
}
