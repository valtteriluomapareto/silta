import GRDB

extension RestoreWriter {
  /// Removes owned document rows and their physical comment-counter scopes.
  func deleteDocuments(workspace: Int64) throws {
    let revisions = """
      SELECT r.id FROM doc_rev r JOIN doc d ON d.id=r.doc_id WHERE d.workspace_id=:ws
      """
    try db.execute(
      sql: """
        DELETE FROM seq_counter WHERE scope IN (
          SELECT 'comment:doc_rev:'||r.id FROM doc_rev r JOIN doc d ON d.id=r.doc_id
          WHERE d.workspace_id=:ws);
        DELETE FROM comment WHERE doc_rev_id IN (\(revisions));
        DELETE FROM doc_verification WHERE doc_rev_id IN (\(revisions));
        DELETE FROM doc_rev WHERE id IN (\(revisions));
        DELETE FROM doc WHERE workspace_id=:ws;
        """, arguments: ["ws": workspace])
  }

  /// Inserts immutable document truth through the caller's UID map.
  mutating func insertDocuments(_ incoming: ExportDocumentSnapshot, workspace: Int64) throws {
    for document in incoming.documents {
      let row = document.row.replacing("current_rev", with: nil, keys: ExportFormat.docKeys)
      try insert("doc", row, extra: ["workspace_id": workspace])
    }
    for document in incoming.documents {
      let owner = try id(document.row.value("uid") ?? "", in: "doc")
      for record in document.records where record.value("table") == "doc_rev" {
        try insert("doc_rev", record, extra: ["doc_id": owner])
      }
    }
    for table in ["doc_verification", "comment"] {
      for document in incoming.documents {
        for record in document.records where record.value("table") == table {
          try insert(table, record, extra: [:], deferred: ["thread"])
        }
      }
    }
    try documentReferences(incoming)
  }

  /// Restores pointers only after all their immutable owners have been inserted.
  private func documentReferences(_ incoming: ExportDocumentSnapshot) throws {
    for document in incoming.documents {
      for record in document.records where record.value("table") == "comment" {
        guard let thread = record.value("thread") else { continue }
        try db.execute(
          sql: "UPDATE comment SET thread_id=? WHERE id=?",
          arguments: [
            try id(thread, in: "comment"), try id(record.value("uid") ?? "", in: "comment"),
          ])
      }
      if let current = document.row.value("current_rev") {
        try db.execute(
          sql: "UPDATE doc SET current_rev=? WHERE id=?",
          arguments: [
            try ExportDocumentSnapshot.positive(current, workspace: slug),
            try id(document.row.value("uid") ?? "", in: "doc"),
          ])
      }
    }
  }

  /// Writes captured/current revision floors and exact incoming comment reservations.
  func restoreDocumentCounters(
    _ incoming: ExportDocumentSnapshot, retaining current: ExportDocumentSnapshot, workspace: Int64
  ) throws -> [ExportRow] {
    var revisions: [String: Int64] = [:]
    for row in current.revisionAllocations + incoming.revisionAllocations {
      guard let name = row.value("slug"), WorkspaceConfig.isValidIdentifier(name) else {
        throw ExportError.invalidTree(
          reason: "a reserved document name is invalid", workspace: slug)
      }
      let next = try ExportDocumentSnapshot.positive(row.value("next"), workspace: slug)
      revisions[name] = max(revisions[name] ?? 1, next)
    }
    for (name, next) in revisions {
      try db.execute(
        sql: """
          INSERT INTO seq_counter(scope,next) VALUES(?,?)
          ON CONFLICT(scope) DO UPDATE SET next=MAX(next,excluded.next)
          """, arguments: ["doc_rev:\(workspace):\(name)", next])
    }
    for row in incoming.commentSequences {
      let owner = try id(row.value("doc_rev") ?? "", in: "doc_rev")
      let next = try ExportDocumentSnapshot.positive(row.value("next"), workspace: slug)
      try db.execute(
        sql: """
          INSERT INTO seq_counter(scope,next) VALUES(?,?)
          ON CONFLICT(scope) DO UPDATE SET next=excluded.next
          """, arguments: ["comment:doc_rev:\(owner)", next])
    }
    return ExportDocumentSnapshot.floorRows(revisions, key: "slug")
  }
}
