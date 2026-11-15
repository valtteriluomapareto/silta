import Foundation

/// Identity fields share one admission rule before ordinary String-key indexing.
enum ExportIdentity {
  static let keys: Set<String> = [
    "uid", "repo", "app", "from_app", "to_app", "to_service", "topic", "parent",
    "source_task", "doc_rev", "thread", "from", "to",
  ]

  static func valid(_ bytes: Data) -> Bool {
    !bytes.isEmpty && bytes.allSatisfy { $0 > 0 && $0 < 128 }
  }

  static var unsupported: CommandFailure {
    CommandFailure(
      error: ExportError.unsupported("stored IDs outside nonempty ASCII text without NUL"),
      next: ["silta backup"],
      message: "Stored IDs must be nonempty ASCII text without NUL. Nothing was changed. "
        + "Create a database backup and ask the human to inspect it before repairing IDs.")
  }
}

extension RestoreValidation {
  /// Walks the actual document bundle supplied by the graph caller as well as base rows.
  func admit(_ documents: ExportDocumentSnapshot) throws {
    func row(_ row: ExportRow, keys: [String], table: String) throws {
      if keys.contains("uid"), row.value("uid") == nil {
        throw invalid("\(table) UID must be nonempty ASCII text without NUL")
      }
      for field in row.fields where ExportIdentity.keys.contains(field.key) {
        guard ExportIdentity.valid(Data(field.value.utf8)) else {
          throw invalid("\(table) \(field.key) must be nonempty ASCII text without NUL")
        }
      }
    }
    try row(tree.workspace, keys: ExportFormat.workspaceKeys, table: "workspace")
    for (section, format) in zip(tree.sections, ExportFormat.sections) {
      for value in section.rows { try row(value, keys: format.keys, table: format.table) }
    }
    for task in tree.tasks {
      try row(task.row, keys: ExportFormat.taskKeys, table: "task")
      for value in task.records {
        let format = ExportFormat.records.first { $0.table == value.value("table") }
        try row(value, keys: format?.keys ?? [], table: format?.table ?? "task record")
      }
    }
    for document in documents.documents {
      try row(document.row, keys: ExportFormat.docKeys, table: "doc")
      for value in document.records {
        let format = ExportFormat.docRecords.first { $0.table == value.value("table") }
        try row(value, keys: format?.keys ?? [], table: format?.table ?? "document record")
      }
    }
    for value in tree.links { try row(value, keys: ExportFormat.linkKeys, table: "link") }
    for value in tree.aliasDecisions {
      try row(value, keys: ExportFormat.aliasDecisionKeys, table: "alias_decision")
    }
    for value in tree.approvals {
      try row(value, keys: ExportFormat.approvalKeys, table: "approval")
    }
  }
}
