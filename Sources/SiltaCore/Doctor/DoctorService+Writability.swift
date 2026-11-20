import Darwin
import Foundation

extension DoctorService {
  static func writability(_ path: String) -> DoctorCheck {
    let file: URL
    do {
      file = URL(filePath: try DatabaseFile(at: path).path)
    } catch {
      if DatabaseFile.isMissing(path) {
        return DoctorCheck(
          id: "database.writable", status: .skipped,
          message: "Database is missing; write access cannot be checked.")
      }
      let message =
        (error as? StorageError) == .invalidDatabaseTarget
        ? StorageError.invalidDatabaseTarget.message
        : "Database path access could not be inspected."
      return DoctorCheck(
        id: "database.writable", status: .fail,
        message: message, next: entryInspection(path), nextBy: .human)
    }
    let directory = file.deletingLastPathComponent()
    let problem: String
    if !FileManager.default.isWritableFile(atPath: file.path) {
      problem = "Database file lacks write access"
    } else if !FileManager.default.isWritableFile(atPath: directory.path)
      || !FileManager.default.isExecutableFile(atPath: directory.path)
    {
      problem = "Database containing directory lacks write or search access"
    } else {
      return DoctorCheck(
        id: "database.writable", status: .pass,
        message: "Database file and containing directory permit writes (permission preflight only)."
      )
    }
    return DoctorCheck(
      id: "database.writable", status: .fail,
      message: problem + "; doctor changes no permissions.", next: entryInspection(file.path),
      nextBy: .human)
  }

  static func entryInspection(_ path: String) -> [String] {
    inspectPaths([path, URL(filePath: path).deletingLastPathComponent().path])
  }

  private static func inspectPaths(_ paths: [String]) -> [String] {
    guard paths.allSatisfy(RestoreService.canNameInRecovery) else { return ["silta doctor --help"] }
    return ["/bin/ls -ld " + paths.map(shellWord).joined(separator: " ")]
  }

  static func loosePermissions(home: URL, path: String) -> DoctorCheck? {
    let home = DirectoryPath.canonicalHome(home)
    guard let file = try? DatabaseFile(at: path) else { return nil }  // Diagnosed separately.
    let entries = [
      (home.path, S_IFDIR), (home.appending(path: "backups").path, S_IFDIR), (file.path, S_IFREG),
    ]
    let loose = entries.compactMap { path, kind -> String? in
      var info = stat()
      guard lstat(path, &info) == 0, info.st_mode & S_IFMT == kind, info.st_mode & 0o077 != 0
      else { return nil }
      return path
    }
    guard !loose.isEmpty else { return nil }
    return DoctorCheck(
      id: "data.permissions", status: .warning,
      message: "Some data paths allow group or other access. Inspect ownership, then set 0600 "
        + "on the database and 0700 on the Silta home and backup directory as needed.",
      next: inspectPaths(loose), nextBy: .human)
  }
}
