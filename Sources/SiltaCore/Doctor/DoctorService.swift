package import Foundation
import GRDB

/// Diagnoses existing data without initializing, migrating, fetching or repairing it.
package enum DoctorService {
  /// Runs independent checks even when the database or git is unavailable.
  package static func inspect(
    store: DatabaseStore, home: URL, git: any GitRunner, at now: Date
  ) async -> DoctorReport {
    var checks = database(store, home: home, at: now)
    let gitCheck: DoctorCheck
    do {
      let result = try await git.run(
        GitRequest(arguments: ["--version"], directory: URL(filePath: "/")))
      let available =
        result.termination == .exit(0)
        && (String(bytes: result.stdout, encoding: .utf8)?.hasPrefix("git version ") == true)
      gitCheck = DoctorCheck(
        id: "git.version", status: available ? "pass" : "fail",
        message: available
          ? "Git is available at /usr/bin/git." : "Git version could not be read at /usr/bin/git.",
        next: available ? [] : ["/usr/bin/git --version"])
    } catch {
      gitCheck = DoctorCheck(
        id: "git.version", status: "fail", message: "Git could not be started at /usr/bin/git.",
        next: ["/usr/bin/git --version"])
    }
    checks.insert(gitCheck, at: 4)
    checks += [
      DoctorCheck(
        id: "install", status: "skipped", message: "Installer diagnostics are not available yet."),
      DoctorCheck(
        id: "index", status: "skipped", message: "Index diagnostics are not available yet."),
      DoctorCheck(
        id: "app.version", status: "skipped",
        message: "App version diagnostics are not available yet."),
    ]
    return DoctorReport(checks: checks)
  }

  private static let dependentIDs = [
    "database.foreign_keys", "database.schema", "database.wal", "git.repos", "git.fetch",
    "git.overrides", "data.claims", "data.backup",
  ]

  private static func skipped(_ ids: [String]) -> [DoctorCheck] {
    ids.map {
      DoctorCheck(id: $0, status: "skipped", message: "Requires a readable, compatible database.")
    }
  }

  private static func database(_ store: DatabaseStore, home: URL, at now: Date) -> [DoctorCheck] {
    let sqlite = "/usr/bin/sqlite3 " + shellWord(store.path)
    let recovery = [sqlite + " 'PRAGMA integrity_check;'", sqlite + " 'PRAGMA foreign_key_check;'"]
    guard FileManager.default.fileExists(atPath: store.path) else {
      return [
        DoctorCheck(
          id: "database.integrity", status: "fail", message: "Database is missing.",
          next: ["silta init"])
      ] + skipped(dependentIDs)
    }
    do {
      return try store.read { db in
        var checks = integrity(db, recovery: recovery)
        let schemaCheck: DoctorCheck
        do { schemaCheck = try schema(db) } catch {
          schemaCheck = DoctorCheck(
            id: "database.schema", status: "fail", message: "Schema metadata could not be checked.",
            next: recovery)
        }
        checks.append(schemaCheck)
        checks.append(wal(home))
        guard schemaCheck.status != "fail" else {
          return checks + skipped(Array(dependentIDs.dropFirst(3).dropLast())) + [
            backup(home, at: now)
          ]
        }
        do { checks += try data(db, at: now) } catch {
          checks += ["git.repos", "git.fetch", "git.overrides"].map {
            DoctorCheck(
              id: $0, status: "fail", message: "Repository metadata could not be checked.",
              next: recovery)
          }
        }
        do { checks.append(try claims(db, at: now)) } catch {
          checks.append(
            DoctorCheck(
              id: "data.claims", status: "fail", message: "Claim metadata could not be checked.",
              next: recovery))
        }
        checks.append(backup(home, at: now))
        return checks
      }
    } catch {
      return [
        DoctorCheck(
          id: "database.integrity", status: "fail",
          message: "Database could not be read or checked.", next: recovery)
      ] + skipped(dependentIDs)
    }
  }

  private static func integrity(_ db: Database, recovery: [String]) -> [DoctorCheck] {
    var checks: [DoctorCheck] = []
    do {
      let valid = try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"]
      checks.append(
        DoctorCheck(
          id: "database.integrity", status: valid ? "pass" : "fail",
          message: valid ? "SQLite integrity check passed." : "SQLite integrity check failed.",
          next: valid ? [] : recovery))
    } catch {
      checks.append(
        DoctorCheck(
          id: "database.integrity", status: "fail",
          message: "SQLite integrity could not be checked.", next: recovery))
    }
    do {
      let valid = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty
      checks.append(
        DoctorCheck(
          id: "database.foreign_keys", status: valid ? "pass" : "fail",
          message: valid ? "Foreign key check passed." : "Foreign key violations exist.",
          next: valid ? [] : [recovery[1]]))
    } catch {
      checks.append(
        DoctorCheck(
          id: "database.foreign_keys", status: "fail",
          message: "Foreign keys could not be checked.", next: [recovery[1]]))
    }
    return checks
  }

  private static func schema(_ db: Database) throws -> DoctorCheck {
    let next = ["update silta"]
    guard try db.tableExists("meta"), try db.tableExists("grdb_migrations"),
      let rawVersion = try String.fetchOne(
        db, sql: "SELECT value FROM meta WHERE key='min_writer_version'"),
      let version = Int(rawVersion)
    else {
      return DoctorCheck(
        id: "database.schema", status: "fail", message: "Schema metadata is missing or invalid.",
        next: next)
    }
    let migrator = StorageSchema.migrator
    let applied = try migrator.appliedIdentifiers(db)
    let complete = Set(migrator.migrations).isSubset(of: applied)
    let future = !applied.subtracting(migrator.migrations).isEmpty
    if !complete, !future, version > 0, version <= DatabaseStore.writerVersion {
      return DoctorCheck(
        id: "database.schema", status: "fail",
        message: "Schema has pending migrations; doctor never migrates it.", next: ["silta init"])
    }
    guard complete, version <= DatabaseStore.writerVersion, version > 0 else {
      return DoctorCheck(
        id: "database.schema", status: "fail",
        message: "Schema requires a compatible Silta binary; doctor never migrates it.", next: next)
    }
    return DoctorCheck(
      id: "database.schema", status: future ? "warning" : "pass",
      message: future
        ? "Newer migrations exist; this binary is still writer-compatible."
        : "Schema is compatible with this binary.", next: future ? next : [])
  }

  static func wal(_ home: URL) -> DoctorCheck {
    do {
      let file = home.appending(path: "silta.db-wal")
      let size =
        FileManager.default.fileExists(atPath: file.path)
        ? try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 : 0
      return DoctorCheck(
        id: "database.wal", status: size > 64 * 1024 * 1024 ? "warning" : "pass",
        message: size > 64 * 1024 * 1024
          ? "WAL exceeds 64 MiB; ask the human to check active database readers."
          : "WAL is at most 64 MiB.",
        next: size > 64 * 1024 * 1024
          ? [
            "/usr/bin/sqlite3 " + shellWord(home.appending(path: "silta.db").path)
              + " 'PRAGMA wal_checkpoint(PASSIVE);'"
          ] : [])
    } catch {
      return DoctorCheck(
        id: "database.wal", status: "warning", message: "WAL size could not be read.",
        next: ["/bin/ls -l " + shellWord(home.path)])
    }
  }

}
