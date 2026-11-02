package import GRDB

extension Workspace: FetchableRecord, MutablePersistableRecord {
  /// Persists workspace values in the owned workspace table.
  package static var databaseTableName: String {
    "workspace"
  }
  /// Maps domain camel-case members to schema columns.
  package static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
    .convertToSnakeCase
  }
  /// Maps schema columns back to domain member names.
  package static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
    .convertFromSnakeCase
  }

  /// Captures the local key assigned by SQLite.
  package mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
