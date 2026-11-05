package import Foundation
package import GRDB

/// Format 1 of the export tree (spec §15): rendering from the database and the strict
/// reader that accepts only what rendering writes.
package enum ExportTree {
  /// The workspace's tree, path to bytes. Throws `ExportError` or `StorageError`.
  package static func render(_ db: Database, workspace slug: String) throws -> [String: Data] {
    try ExportSnapshot.read(db, workspace: slug).files()
  }

  /// Parses a tree; anything not byte for byte what export writes is `invalidTree`.
  package static func parse(_ files: [String: Data]) throws -> ExportSnapshot {
    throw ExportError.invalidTree("not implemented")
  }
}
