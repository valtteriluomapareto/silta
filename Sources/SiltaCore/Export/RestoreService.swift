package import Foundation

/// Replaces one workspace from an export tree (spec §15).
package enum RestoreService {
  /// Restores the tree in `directory`. Throws `ExportError`, `StorageError` or
  /// `ActorError`; on failure the database is as it was.
  package static func restore(
    from directory: URL, workspace expected: String?, store: DatabaseStore, home: URL,
    identity: (ids: any IDGenerator, date: Date), approval: HumanApproval?, dryRun: Bool
  ) throws -> RestoreReport {
    throw ExportError.invalidTree("not implemented")
  }
}
