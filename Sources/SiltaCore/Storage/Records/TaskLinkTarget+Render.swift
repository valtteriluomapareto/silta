import GRDB

extension TaskLinkTarget {
  /// This target as a stored link row renders it, e.g. `task:AC-2`.
  func rendered(in db: Database) throws -> String {
    try Self.render(
      Row(["to_kind": kind, "to_id": id, "to_ext": external, "anchor": anchor]), in: db)
  }

  static func render(_ row: Row, in db: Database) throws -> String {
    let kind: String = row["to_kind"]
    if let external: String = row["to_ext"] { return kind + ":" + external }
    guard let id: Int64 = row["to_id"] else { throw StorageError.corrupt }
    let anchor: String? = row["anchor"]
    if kind == "task", let anchor, anchor.hasPrefix("plan#") { return anchor }
    if kind == "task" { return "task:" + (try taskRef(id, in: db)) }
    if ["app", "topic", "doc", "service"].contains(kind) {
      return try slugRef(kind, id: id, in: db)
    }
    if kind == "edge" { return try edgeRef(id, in: db) }
    if kind == "task_plan_rev" {
      guard
        let rev = try Int.fetchOne(
          db, sql: "SELECT rev FROM task_plan_rev WHERE id=?",
          arguments: [id])
      else { throw StorageError.corrupt }
      return "plan@\(rev)" + (anchor ?? "")
    }
    if kind == "doc_rev" { return try docRef(id, in: db) }
    if kind == "comment" { return try commentRef(id, in: db) }
    throw StorageError.corrupt
  }

  private static func slugRef(_ kind: String, id: Int64, in db: Database) throws -> String {
    guard
      let slug = try String.fetchOne(
        db, sql: "SELECT slug FROM \(kind) WHERE id=?",
        arguments: [id])
    else { throw StorageError.corrupt }
    return kind + ":" + (kind == "service" ? encodeComponent(slug) : slug)
  }

  static func encodeComponent(_ value: String) -> String {
    value.utf8.map { byte in
      if (65...90).contains(byte) || (97...122).contains(byte)
        || (48...57).contains(byte) || byte == 45 || byte == 95
      {
        return String(UnicodeScalar(byte))
      }
      let hex = String(byte, radix: 16, uppercase: true)
      return "%" + (hex.count == 1 ? "0" : "") + hex
    }.joined()
  }

  private static func edgeRef(_ id: Int64, in db: Database) throws -> String {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT source.slug AS source,target.slug AS target,service.slug AS service,edge.kind
          FROM edge JOIN app source ON source.id=edge.from_app_id
          LEFT JOIN app target ON target.id=edge.to_app_id
          LEFT JOIN service ON service.id=edge.to_service_id WHERE edge.id=?
          """, arguments: [id])
    else { throw StorageError.corrupt }
    let service: String? = row["service"]
    let app: String? = row["target"]
    guard let target = service.map({ "service:" + encodeComponent($0) }) ?? app else {
      throw StorageError.corrupt
    }
    let source: String = row["source"]
    let kind: String = row["kind"]
    return "edge:" + source + "/" + target + "/" + encodeComponent(kind)
  }

  private static func commentRef(_ id: Int64, in db: Database) throws -> String {
    guard
      let comment = try Row.fetchOne(
        db, sql: "SELECT * FROM comment WHERE id=?",
        arguments: [id])
    else { throw StorageError.corrupt }
    let seq: Int = comment["seq"]
    if let task: Int64 = comment["task_id"] { return try taskRef(task, in: db) + "/\(seq)" }
    guard let revision: Int64 = comment["doc_rev_id"] else { throw StorageError.corrupt }
    return try docRef(revision, in: db) + "/\(seq)"
  }

  private static func taskRef(_ id: Int64, in db: Database) throws -> String {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT workspace.task_prefix,task.seq FROM task
          JOIN workspace ON workspace.id=task.workspace_id
          WHERE task.id=?
          """, arguments: [id])
    else { throw StorageError.corrupt }
    return "\(row["task_prefix"] as String)-\(row["seq"] as Int)"
  }

  private static func docRef(_ id: Int64, in db: Database) throws -> String {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT doc.slug,doc_rev.rev FROM doc_rev
          JOIN doc ON doc.id=doc_rev.doc_id
          WHERE doc_rev.id=?
          """, arguments: [id])
    else { throw StorageError.corrupt }
    return "doc:\(row["slug"] as String)@\(row["rev"] as Int)"
  }
}
