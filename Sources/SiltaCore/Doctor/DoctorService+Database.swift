import Foundation
import GRDB

extension DoctorService {
  private static func skipped(_ ids: [String]) -> [DoctorCheck] {
    ids.map {
      DoctorCheck(id: $0, status: .skipped, message: "Requires a readable, compatible database.")
    }
  }

  static func database(_ store: DatabaseStore, backups: DoctorBackups, at now: Date)
    -> [DoctorCheck]
  {
    let evidence = "/usr/bin/sqlite3 -readonly " + shellWord(store.path)
    let inspectBackups = !backups.isKnownEmpty
    let recovery =
      (inspectBackups ? [backups.listing] : [])
      + [
        evidence + " 'PRAGMA integrity_check;'", evidence + " 'PRAGMA foreign_key_check;'",
        evidence + " '.schema'",
      ]
    let missing = !FileManager.default.fileExists(atPath: store.path)
    if missing || !FileManager.default.isReadableFile(atPath: store.path) {
      let first: DoctorCheck
      if missing {
        first = DoctorCheck(
          id: "database.integrity", status: .fail,
          message: "Database \(store.path.debugDescription) is missing."
            + (backups.count > 0
              ? " Backups are available; restore is the human's decision."
              : !backups.readable
                ? " Backup availability is unknown; "
                  + "the human must decide recovery after inspection."
                : " Initialize only if no existing data is expected."),
          next: inspectBackups ? [backups.listing] : ["silta init"],
          nextBy: inspectBackups ? .agent : .human)
      } else {
        first = DoctorCheck(
          id: "database.integrity", status: .fail,
          message:
            "Database access is denied by file permissions; "
            + "inspect access before diagnosing corruption.",
          next: (inspectBackups ? [backups.listing] : []) + [
            "/bin/ls -l " + shellWord(store.path)
          ])
      }
      return [first] + skipped(["database.foreign_keys", "database.schema"] + dependentIDs)
        + [backups.check(expectedDay: nil)]
    }
    do {
      return try store.read { db in
        databaseChecks(db, path: store.path, backups: backups, recovery: recovery, at: now)
      }
    } catch {
      let failure = readFailure(
        StorageError.mapped(error, at: store.path), path: store.path, recovery: recovery,
        hasBackups: backups.count > 0)
      return [failure] + skipped(["database.foreign_keys", "database.schema"] + dependentIDs)
        + [backups.check(expectedDay: nil)]
    }
  }

  static func readFailure(_ error: StorageError, path: String, recovery: [String], hasBackups: Bool)
    -> DoctorCheck
  {
    let evidence = "/bin/ls -l " + shellWord(path)
    switch error {
    case .busy, .locked:
      return DoctorCheck(
        id: "database.integrity", status: .fail,
        message: error == .busy
          ? "Database is busy; inspect open handles, then retry once."
          : "Database is locked; inspect open handles, then retry once.",
        next: ["/usr/sbin/lsof " + shellWord(path)])
    case .accessDenied:
      return DoctorCheck(
        id: "database.integrity", status: .fail,
        message: "Database access is denied by file permissions or a read-only file or directory; "
          + "inspect access and the resolved database path.",
        next: recovery + [evidence], nextBy: .human)
    case .corrupt:
      return DoctorCheck(
        id: "database.integrity", status: .fail,
        message: "SQLite reports the database is corrupt or is not a SQLite database; "
          + "inspect backups and read-only evidence; restore is the human's decision.",
        next: recovery, nextBy: .human)
    case .diskFull, .ioFailure, .walRefused:
      return DoctorCheck(
        id: "database.integrity", status: .fail,
        message: "Database file could not be read or written because of a filesystem failure; "
          + "inspect free space and the resolved database path.",
        next: recovery, nextBy: .human)
    default:
      return DoctorCheck(
        id: "database.integrity", status: .fail,
        message: "Database could not be opened or read."
          + (hasBackups
            ? " Backups are available; restore is the human's decision."
            : " Inspect the read-only evidence before deciding recovery."),
        next: recovery)
    }
  }

  private static func databaseChecks(
    _ db: Database, path: String, backups: DoctorBackups, recovery: [String], at now: Date
  ) -> [DoctorCheck] {
    var checks = integrity(db, recovery: recovery)
    let schemaCheck: DoctorCheck
    do {
      schemaCheck = try schema(
        db, path: path, recovery: recovery, allowInitialization: backups.isKnownEmpty)
    } catch {
      schemaCheck = DoctorCheck(
        id: "database.schema", status: .fail, message: "Schema metadata could not be checked.",
        next: recovery)
    }
    checks.append(schemaCheck)
    let expected: String?
    do {
      expected =
        try db.tableExists("meta")
        ? try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='last_backup_day'") : nil
    } catch { expected = nil }
    checks.append(backups.check(expectedDay: expected))
    guard schemaCheck.status != .fail else { return checks + skipped(dependentIDs) }
    do { checks += try data(db, at: now) } catch {
      checks += ["git.repos", "git.bindings", "git.fetch", "git.overrides"].map {
        DoctorCheck(
          id: $0, status: .fail, message: "Repository metadata could not be checked.",
          next: recovery)
      }
    }
    do { checks.append(try claims(db, at: now)) } catch {
      checks.append(
        DoctorCheck(
          id: "data.claims", status: .fail, message: "Claim metadata could not be checked.",
          next: recovery))
    }
    return checks
  }

  private static func integrity(_ db: Database, recovery: [String]) -> [DoctorCheck] {
    var checks: [DoctorCheck] = []
    do {
      let valid = try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"]
      checks.append(
        DoctorCheck(
          id: "database.integrity", status: valid ? .pass : .fail,
          message: valid
            ? "SQLite integrity check passed."
            : "SQLite integrity check failed; inspect backups and read-only evidence. "
              + "Restore is the human's decision.",
          next: valid ? [] : recovery))
    } catch {
      checks.append(
        DoctorCheck(
          id: "database.integrity", status: .fail,
          message: "SQLite integrity could not be checked.", next: recovery))
    }
    do {
      let valid = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty
      checks.append(
        DoctorCheck(
          id: "database.foreign_keys", status: valid ? .pass : .fail,
          message: valid ? "Foreign key check passed." : "Foreign key violations exist.",
          next: valid ? [] : recovery))
    } catch {
      checks.append(
        DoctorCheck(
          id: "database.foreign_keys", status: .fail, message: "Foreign keys could not be checked.",
          next: recovery))
    }
    return checks
  }

  private static func schema(
    _ db: Database, path: String, recovery: [String], allowInitialization: Bool
  ) throws
    -> DoctorCheck
  {
    let install = ["<clean-main-checkout>/scripts/install-dev.sh"]
    guard try db.tableExists("meta"), try db.tableExists("grdb_migrations") else {
      return try missingMetadata(
        db, path: path, recovery: recovery, allowInitialization: allowInitialization)
    }
    guard
      let rawVersion = try String.fetchOne(
        db, sql: "SELECT value FROM meta WHERE key='min_writer_version'"),
      let version = Int(rawVersion), version > 0
    else {
      return DoctorCheck(
        id: "database.schema", status: .fail,
        message:
          "Writer version metadata is missing or invalid; "
          + "install a compatible binary from clean main.",
        next: install, nextBy: .human)
    }
    let migrator = StorageSchema.migrator
    let applied = try migrator.appliedIdentifiers(db)
    let complete = Set(migrator.migrations).isSubset(of: applied)
    let future = !applied.subtracting(migrator.migrations).isEmpty
    if !complete, !future, version <= DatabaseStore.writerVersion {
      return DoctorCheck(
        id: "database.schema", status: .fail,
        message:
          "Database \(path.debugDescription) has pending migrations; doctor never migrates it.",
        next: ["silta init"], nextBy: .human)
    }
    guard complete, version <= DatabaseStore.writerVersion else {
      return DoctorCheck(
        id: "database.schema", status: .fail,
        message:
          "Schema requires a compatible Silta binary; "
          + "development installs use scripts/install-dev.sh from clean main.",
        next: install, nextBy: .human)
    }
    return DoctorCheck(
      id: "database.schema", status: future ? .warning : .pass,
      message: future
        ? "Newer migrations exist; this binary is still writer-compatible."
        : "Schema is compatible with this binary.", next: future ? install : [],
      nextBy: future ? .human : .agent)
  }

  private static func missingMetadata(
    _ db: Database, path: String, recovery: [String], allowInitialization: Bool
  ) throws -> DoctorCheck {
    let empty =
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0
    let initialize = empty && allowInitialization
    return DoctorCheck(
      id: "database.schema", status: .fail,
      message: initialize
        ? "Database \(path.debugDescription) has no initialized schema; confirm this is the intended home."
        : "Database metadata is absent; "
          + "inspect backups and read-only evidence. "
          + "Restore is the human's decision.",
      next: initialize ? ["silta init"] : recovery,
      nextBy: initialize ? .human : .agent)
  }

}
