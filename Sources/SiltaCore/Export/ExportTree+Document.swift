import Foundation

extension ExportTree {
  static func parseDocument(
    _ files: [String: Data], slug: String, workspace: String
  ) throws -> ExportDocument {
    throw ExportError.unsupported("document file pairs")
  }
}
