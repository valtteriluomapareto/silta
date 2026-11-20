import GRDB

/// A persistent serialized reader whose version values share one SQLite connection.
package struct DatabaseChangeProbe: Sendable {
  private let connection: DatabaseStore.Connection
  private let path: String

  /// Opens an existing store without creating it or applying migrations.
  package init(store: DatabaseStore) throws {
    connection = try store.openReader()
    path = store.path
  }

  package func isCurrent() -> Bool {
    do {
      try connection.file.requireCurrent(at: path)
      return true
    } catch { return false }
  }

  /// Checks compatibility and samples the connection-local version in one read transaction.
  package func sample() throws -> (version: Int, needsMigration: Bool) {
    do {
      return try connection.queue.read { db in
        try connection.file.requireCurrent(at: path)
        let pending = try DatabaseStore.readerNeedsMigration(in: db)
        guard let version = try Int.fetchOne(db, sql: "PRAGMA data_version") else {
          throw StorageError.corrupt
        }
        try connection.file.requireCurrent(at: path)
        return (version, pending)
      }
    } catch let error as any CodedError {
      throw error
    } catch {
      throw StorageError.mapped(error, at: path)
    }
  }
}
