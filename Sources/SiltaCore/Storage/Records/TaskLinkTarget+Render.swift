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
    guard let id: Int64 = row["to_id"] else { throw StorageError.unavailable }
    let anchor: String? = row["anchor"]
    if kind == "task", let anchor, anchor.hasPrefix("plan#") { return anchor }
    if kind == "task" { return "task:" + (try taskRef(id, in: db)) }
    if ["app", "topic", "doc"].contains(kind) {
      guard
        let slug = try String.fetchOne(
          db, sql: "SELECT slug FROM \(kind) WHERE id=?",
          arguments: [id])
      else { throw StorageError.unavailable }
      return kind + ":" + slug
    }
    if kind == "task_plan_rev" {
      guard
        let rev = try Int.fetchOne(
          db, sql: "SELECT rev FROM task_plan_rev WHERE id=?",
          arguments: [id])
      else { throw StorageError.unavailable }
      return "plan@\(rev)" + (anchor ?? "")
    }
    if kind == "doc_rev" { return try docRef(id, in: db) }
    if kind == "comment" { return try commentRef(id, in: db) }
    throw StorageError.unavailable
  }

  private static func commentRef(_ id: Int64, in db: Database) throws -> String {
    guard
      let comment = try Row.fetchOne(
        db, sql: "SELECT * FROM comment WHERE id=?",
        arguments: [id])
    else { throw StorageError.unavailable }
    let seq: Int = comment["seq"]
    if let task: Int64 = comment["task_id"] { return try taskRef(task, in: db) + "/\(seq)" }
    guard let revision: Int64 = comment["doc_rev_id"] else { throw StorageError.unavailable }
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
    else { throw StorageError.unavailable }
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
    else { throw StorageError.unavailable }
    return "doc:\(row["slug"] as String)@\(row["rev"] as Int)"
  }
}
