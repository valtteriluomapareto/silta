import Foundation

/// One document's metadata, immutable revisions and attributed records.
struct ExportDocument: Equatable, Sendable {
  var slug: String
  var row: ExportRow
  var records: [ExportRow]

  func files() throws -> [String: Data] {
    throw ExportError.unsupported("document file pairs")
  }
}
