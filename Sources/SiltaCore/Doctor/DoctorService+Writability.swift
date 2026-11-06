import Darwin
import Foundation

extension DoctorService {
  static func writability(_ path: String) -> DoctorCheck {
    let resolved = realpath(path, nil)
    defer { if let resolved { free(resolved) } }
    let file = URL(filePath: resolved.map { String(cString: $0) } ?? path)
    let directory = file.deletingLastPathComponent()
    let inspection = "/bin/ls -ld " + shellWord(file.path) + " " + shellWord(directory.path)
    var info = stat()
    let problem: String
    if stat(file.path, &info) != 0 {
      if errno == ENOENT {
        return DoctorCheck(
          id: "database.writable", status: .skipped,
          message: "Database is missing; write access cannot be checked.")
      }
      problem = "Database path access could not be inspected"
    } else if info.st_mode & S_IFMT != S_IFREG {
      problem = "Database path is not a regular file"
    } else if !FileManager.default.isWritableFile(atPath: file.path) {
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
      message: problem + "; doctor changes no permissions.", next: [inspection], nextBy: .human)
  }
}
