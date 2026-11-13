import Foundation
import GRDB

extension ExportSnapshot {
  /// Captures all representable rows without imposing incoming graph rules.
  static func capture(_ db: Database, workspace: String) throws -> Self {
    throw ExportError.unsupported("document snapshot composition")
  }
}

extension ExportTree {
  /// Parses all represented file groups with strict canonical byte comparison.
  static func parseSnapshot(_ files: [String: Data]) throws -> ExportSnapshot {
    throw ExportError.unsupported("document parser composition")
  }
}
