package import Foundation

/// What an export wrote.
package struct ExportResult: Encodable, Sendable {
  /// The workspace slug.
  package let workspace: String
  /// The absolute path of the written tree, `<root>/<workspace>`.
  package let path: String
  /// The number of files in the tree, the manifest included.
  package let files: Int
}

/// Writes export trees to disk (spec §15).
package enum ExportService {
  /// Writes `<root>/<workspace>` from one read transaction. The target must be absent or
  /// a previous export; it is replaced by a staged tree in one swap. Throws
  /// `ExportError`, `StorageError` or `WorkspaceError`; on failure the target is as it was.
  package static func export(
    workspace slug: String, to root: URL, store: DatabaseStore, home: URL
  ) throws -> ExportResult {
    throw ExportError.unwritable(path: root.path)
  }
}
