import Foundation
import GRDB

/// Document truth and standalone allocation streams, independent of physical IDs.
struct ExportDocumentSnapshot: Equatable, Sendable {
  var documents: [ExportDocument]
  var revisionAllocations: [ExportRow]
  var commentSequences: [ExportRow]

  static func read(_ db: Database, workspace: Int64) throws -> Self {
    throw ExportError.unsupported("document snapshots")
  }

  static func parse(_ files: [String: Data], workspace: String) throws -> Self {
    throw ExportError.unsupported("document snapshot streams")
  }

  func files() throws -> [String: Data] {
    throw ExportError.unsupported("document snapshot streams")
  }
}
