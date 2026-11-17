import GRDB

/// A persistent serialized reader whose version values share one SQLite connection.
package struct DatabaseChangeProbe: Sendable {
  private let queue: DatabaseQueue
  private let path: String

  /// Opens an existing store without creating it or applying migrations.
  package init(store: DatabaseStore) throws {
    queue = try store.openReader()
    path = store.path
  }

  /// Checks compatibility and samples the connection-local version in one read transaction.
  package func sample() throws -> (version: Int, needsMigration: Bool) {
    do {
      return try queue.read { db in
        let pending = try DatabaseStore.readerNeedsMigration(in: db)
        guard let version = try Int.fetchOne(db, sql: "PRAGMA data_version") else {
          throw StorageError.corrupt
        }
        return (version, pending)
      }
    } catch let error as any CodedError {
      throw error
    } catch {
      throw StorageError.mapped(error, at: path)
    }
  }
}
