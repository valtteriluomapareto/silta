import GRDB

extension RestoreWriter {
  /// Removes owned document rows and their physical comment-counter scopes.
  func deleteDocuments(workspace: Int64) throws {
    throw ExportError.unsupported("document row replacement")
  }

  /// Inserts immutable document truth through the caller's UID map.
  mutating func insertDocuments(_ incoming: ExportDocumentSnapshot, workspace: Int64) throws {
    throw ExportError.unsupported("document row replacement")
  }

  /// Writes captured/current revision floors and exact incoming comment reservations.
  func restoreDocumentCounters(
    _ incoming: ExportDocumentSnapshot, retaining current: ExportDocumentSnapshot, workspace: Int64
  ) throws -> [ExportRow] {
    throw ExportError.unsupported("document allocation replacement")
  }
}
