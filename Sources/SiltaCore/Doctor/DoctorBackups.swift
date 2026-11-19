import Darwin
import Foundation

/// File-only evidence remains available even when the truth database cannot open.
struct DoctorBackups {
  let directory: URL
  let days: [String]
  let count: Int
  let readable: Bool
  let invalidDirectory: Bool

  init(home: URL, at now: Date) {
    directory = DirectoryPath.canonicalHome(home).appending(path: "backups")
    do {
      let descriptor = try DirectoryPath.open(directory)
      defer { close(descriptor) }
      var daily: [String] = []
      var published = 0
      let today = utcDay(now)
      for name in try DirectoryPath.names(in: descriptor) {
        guard
          let day = StorageBackup.day(of: name, manual: false)
            ?? StorageBackup.day(of: name, manual: true),
          StorageBackup.validDay(day), day <= today,
          (StorageBackup.regularSize(name, in: descriptor) ?? 0) > 0
        else { continue }
        published += 1
        if name == "silta-\(day).db" { daily.append(day) }
      }
      days = daily.sorted()
      count = published
      readable = true
      invalidDirectory = false
    } catch let error as POSIXError {
      days = []
      count = 0
      readable = error.code == .ENOENT
      invalidDirectory = error.code == .ENOTDIR || error.code == .ELOOP
    } catch {
      days = []
      count = 0
      readable = false
      invalidDirectory = false
    }
  }

  /// Unknown availability never establishes that recovery evidence is absent.
  var isKnownEmpty: Bool { readable && count == 0 }

  var listing: String { "/bin/ls -l " + shellWord(directory.path) }

  func check(expectedDay: String?) -> DoctorCheck {
    if invalidDirectory {
      return DoctorCheck(
        id: "data.backup", status: .warning,
        message: "The backups entry must be a directory without symbolic links.",
        next: [DoctorService.inspectManagedPath(directory)])
    }
    guard readable else {
      return DoctorCheck(
        id: "data.backup", status: .warning,
        message: "Backup files could not be listed.", next: [listing])
    }
    if expectedDay == "" {
      return DoctorCheck(
        id: "data.backup", status: .pass,
        message: "No daily backup yet; the first write creates one.")
    }
    guard let expectedDay else {
      return DoctorCheck(
        id: "data.backup", status: .warning,
        message: count == 0
          ? "No published backups found; the last backup day could not be read."
          : "\(count) published backup(s) found; the last backup day could not be read.",
        next: count > 0 ? [listing] : [])
    }
    let covered = StorageBackup.validDay(expectedDay) && days.contains(expectedDay)
    return DoctorCheck(
      id: "data.backup", status: covered ? .pass : .warning,
      message: covered
        ? "The recorded daily backup is present."
        : "The recorded daily backup is missing or invalid.",
      next: covered ? [] : [listing])
  }
}
