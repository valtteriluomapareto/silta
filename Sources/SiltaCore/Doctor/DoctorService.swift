package import Foundation

/// Diagnoses existing data without initializing, migrating, fetching or repairing it.
package enum DoctorService {
  /// Stable display order, matching spec §19. New checks are added without renaming ids.
  static let checkOrder = [
    "database.integrity", "database.foreign_keys", "database.schema", "database.writable",
    "database.wal",
    "git.version", "git.repos", "git.bindings", "git.fetch", "git.overrides", "data.claims",
    "data.backup",
    "install.path", "install.hook", "install.skill", "install.codex_root", "install.codex_marker",
    "index.integrity", "index.foreign_keys", "index.schema", "index.fts", "index.age",
    "app.version",
  ]
  static let dependentIDs = [
    "git.repos", "git.bindings", "git.fetch", "git.overrides", "data.claims",
  ]

  /// Runs independent checks even when the database or git is unavailable.
  package static func inspect(store: DatabaseStore, home: URL, git: any GitRunner, at now: Date)
    async -> DoctorReport
  {
    let backups = DoctorBackups(home: home, at: now)
    var checks = database(store, backups: backups, at: now)
    checks.append(writability(store.path))
    checks.append(wal(home))
    checks.append(await gitVersion(git))
    return DoctorReport(checks: orderedChecks(checks))
  }

  /// Fills reserved ids while retaining unregistered computed checks visibly.
  static func orderedChecks(_ checks: [DoctorCheck]) -> [DoctorCheck] {
    let ordered = checkOrder.map { id in
      if let check = checks.first(where: { $0.id == id }) { return check }
      let message =
        id.hasPrefix("install.")
        ? "Installer diagnostics are not available yet."
        : id.hasPrefix("index.")
          ? "Index diagnostics are not available yet."
          : id == "app.version"
            ? "App version diagnostics are not available yet."
            : "This diagnostic check is unavailable."
      return DoctorCheck(id: id, status: .skipped, message: message)
    }
    return ordered + checks.filter { !checkOrder.contains($0.id) }
  }

  private static func gitVersion(_ git: any GitRunner) async -> DoctorCheck {
    do {
      let result = try await git.run(
        GitRequest(arguments: ["--version"], directory: URL(filePath: "/")))
      let available =
        result.termination == .exit(0)
        && String(bytes: result.stdout, encoding: .utf8)?.hasPrefix("git version ") == true
      return DoctorCheck(
        id: "git.version", status: available ? .pass : .fail,
        message: available
          ? "Git is available at /usr/bin/git." : "Git version could not be read at /usr/bin/git.",
        next: available ? [] : ["/usr/bin/git --version"])
    } catch {
      return DoctorCheck(
        id: "git.version", status: .fail, message: "Git could not be started at /usr/bin/git.",
        next: ["/usr/bin/git --version"])
    }
  }

  static func wal(_ home: URL) -> DoctorCheck {
    do {
      let file = home.appending(path: "silta.db-wal")
      let size =
        FileManager.default.fileExists(atPath: file.path)
        ? try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 : 0
      let large = size > 64 * 1024 * 1024
      return DoctorCheck(
        id: "database.wal", status: large ? .warning : .pass,
        message: large
          ? "WAL exceeds 64 MiB; inspect active database readers before deciding on repairs."
          : "WAL is at most 64 MiB.",
        next: large ? ["/usr/sbin/lsof " + shellWord(home.appending(path: "silta.db").path)] : [])
    } catch {
      return DoctorCheck(
        id: "database.wal", status: .warning, message: "WAL size could not be read.",
        next: ["/bin/ls -l " + shellWord(home.path)])
    }
  }
}
