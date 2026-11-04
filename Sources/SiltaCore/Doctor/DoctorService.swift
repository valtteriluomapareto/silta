package import Foundation

/// Diagnoses existing data without initializing, migrating, fetching or repairing it.
package enum DoctorService {
  /// Stable display order, matching spec §19. New checks are added without renaming ids.
  static let checkOrder = [
    "database.integrity", "database.foreign_keys", "database.schema", "database.wal",
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
    checks.append(wal(home))
    checks.append(await gitVersion(git))
    checks += [
      "install.path", "install.hook", "install.skill", "install.codex_root", "install.codex_marker",
    ].map {
      DoctorCheck(id: $0, status: .skipped, message: "Installer diagnostics are not available yet.")
    }
    checks += ["index.integrity", "index.foreign_keys", "index.schema", "index.fts", "index.age"]
      .map {
        DoctorCheck(id: $0, status: .skipped, message: "Index diagnostics are not available yet.")
      }
    checks.append(
      DoctorCheck(
        id: "app.version", status: .skipped,
        message: "App version diagnostics are not available yet."))
    return DoctorReport(checks: checkOrder.compactMap { id in checks.first { $0.id == id } })
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
