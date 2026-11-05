import GRDB

extension RestoreWriter {
  /// Inserts one row; `deferred` reference keys are filled in a second pass.
  @discardableResult
  mutating func insert(
    _ table: String, _ row: ExportRow, extra: [String: (any DatabaseValueConvertible)?],
    deferred: Set<String> = []
  ) throws -> Int64 {
    var columns = Array(extra.keys.sorted())
    var values: [(any DatabaseValueConvertible)?] = columns.map { extra[$0] ?? nil }
    let references = ExportFormat.references[table] ?? [:]
    // A task's `ref` and a record's `table` are display and file framing, not columns.
    let framing = table == "task" ? "ref" : "table"
    for field in row.fields where field.key != framing {
      if let reference = references[field.key] {
        columns.append(reference.column)
        values.append(deferred.contains(field.key) ? nil : try id(field.value, in: reference.table))
      } else {
        columns.append(field.key)
        values.append(
          ExportFormat.integerKeys.contains(field.key) ? Int64(field.value) : field.value)
      }
    }
    let placeholders = columns.map { _ in "?" }.joined(separator: ",")
    try db.execute(
      sql:
        "INSERT INTO \(table)(\(columns.joined(separator: ","))) VALUES(\(placeholders))",
      arguments: StatementArguments(values))
    let rowID = db.lastInsertedRowID
    if let uid = row.value("uid") { ids[table, default: [:]][uid] = rowID }
    return rowID
  }

  func id(_ uid: String, in table: String) throws -> Int64 {
    guard let id = ids[table]?[uid] else {
      throw ExportError.invalidTree("\(uid) names no \(table) of the tree")
    }
    return id
  }

  mutating func insertTasks(workspace: Int64) throws {
    for task in tree.tasks {
      try insert("task", task.row, extra: ["workspace_id": workspace], deferred: ["parent"])
    }
    for task in tree.tasks {
      guard let uid = task.row.value("uid"), let parent = task.row.value("parent") else { continue }
      try db.execute(
        sql: "UPDATE task SET parent_id=? WHERE id=?",
        arguments: [try id(parent, in: "task"), try id(uid, in: "task")])
    }
    for task in tree.tasks {
      let taskUID = task.row.value("uid") ?? ""
      let taskID = try id(taskUID, in: "task")
      for record in task.records {
        let table = record.value("table") ?? ""
        let rowID = try insert(table, record, extra: ["task_id": taskID], deferred: ["thread"])
        if table == "task_plan_rev" { revisions["\(taskUID)@\(record.value("rev") ?? "")"] = rowID }
      }
      for record in task.records {
        guard let uid = record.value("uid"), let thread = record.value("thread") else { continue }
        try db.execute(
          sql: "UPDATE comment SET thread_id=? WHERE id=?",
          arguments: [try id(thread, in: "comment"), try id(uid, in: "comment")])
      }
    }
  }

  mutating func insertLinks(workspace: Int64) throws {
    for link in tree.links {
      let fromKind = link.value("from_kind") ?? ""
      let toKind = link.value("to_kind") ?? ""
      let from = try id(link.value("from") ?? "", in: ExportFormat.linkTables[fromKind] ?? fromKind)
      var to: Int64?
      if let target = link.value("to") {
        if toKind == "task_plan_rev" {
          guard let revision = revisions["\(target)@\(link.value("to_rev") ?? "")"] else {
            throw ExportError.invalidTree("a link names a plan revision the tree doesn't hold")
          }
          to = revision
        } else {
          to = try id(target, in: ExportFormat.linkTables[toKind] ?? toKind)
        }
      }
      try db.execute(
        sql: """
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,to_ext,created_by,
            created_at,anchor) VALUES(?,?,?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          link.value("uid"), workspace, fromKind, from, link.value("rel"), toKind, to,
          link.value("to_ext"), link.value("created_by"), link.value("created_at"),
          link.value("anchor"),
        ])
    }
  }

  /// The task counter never rewinds: refs already cited are never reused.
  func counter(workspace: Int64) throws {
    let scope = "task:\(workspace)"
    let stored = try Int64.fetchOne(
      db, sql: "SELECT next FROM seq_counter WHERE scope=?", arguments: [scope])
    let highest = tree.tasks.compactMap { Int64($0.row.value("seq") ?? "") }.max() ?? 0
    let next =
      [stored, tree.workspace.value("next_task_seq").flatMap { Int64($0) }, highest + 1]
      .compactMap { $0 }.max() ?? highest + 1
    guard stored != nil || !tree.tasks.isEmpty || tree.workspace.value("next_task_seq") != nil
    else { return }
    try db.execute(
      sql: """
        INSERT INTO seq_counter(scope,next) VALUES(?,?)
        ON CONFLICT(scope) DO UPDATE SET next=excluded.next
        """, arguments: [scope, next])
  }

  /// Approvals are never deleted; the tree's are added when their uid is missing.
  mutating func mergeApprovals() throws {
    for row in tree.approvals {
      try db.execute(
        sql: """
          INSERT INTO approval(uid,workspace,actor,command,words,created_at) VALUES(?,?,?,?,?,?)
          ON CONFLICT(uid) DO NOTHING
          """,
        arguments: [
          row.value("uid"), slug, row.value("actor"), row.value("command"), row.value("words"),
          row.value("created_at"),
        ])
      if db.changesCount > 0 {
        approvalsAdded += 1
        try tx.recordChange(kind: "approval", rowID: db.lastInsertedRowID)
      }
    }
  }
}
