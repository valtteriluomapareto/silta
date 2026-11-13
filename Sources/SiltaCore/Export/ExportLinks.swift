import GRDB

/// Workspace-owned link rows with typed stable UID ends.
enum ExportLinks {
  static func read(_ db: Database, workspace: Int64) throws -> [ExportRow] {
    throw ExportError.unsupported("typed document links")
  }
}
