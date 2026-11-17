import GRDB

extension DatabaseStore {
  /// Reports pending known migrations and refuses unknown ones without applying either.
  /// The writer-version floor remains a write-only gate (D32).
  package func readerNeedsMigration() throws -> Bool {
    try read { db in
      let migrator = StorageSchema.migrator
      let applied = try migrator.appliedIdentifiers(db)
      let known = Set(migrator.migrations)
      guard applied.isSubset(of: known) else { throw StorageError.schemaTooNew }
      return applied != known
    }
  }
}
