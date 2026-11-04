import Foundation

/// File-only evidence remains available even when the truth database cannot open.
struct DoctorBackups {
  let directory: URL
  let days: [String]
  let count: Int
  let readable: Bool

  init(home: URL, at now: Date) {
    directory = home.appending(path: "backups")
    do {
      let files =
        FileManager.default.fileExists(atPath: directory.path)
        ? try FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) : []
      var daily: [String] = []
      var published = 0
      for file in files {
        let name = file.lastPathComponent
        guard
          name.wholeMatch(
            of: /silta-[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-before-[A-Za-z0-9]+-[0-9]+)?\.db/) != nil
        else { continue }
        let values = try file.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          (values.fileSize ?? 0) > 0
        else { continue }
        let day = String(name.dropFirst(6).prefix(10))
        guard Self.validDay(day), day <= utcDay(now) else { continue }
        published += 1
        if name == "silta-\(day).db" { daily.append(day) }
      }
      days = daily.sorted()
      count = published
      readable = true
    } catch {
      days = []
      count = 0
      readable = false
    }
  }

  var listing: String { "/bin/ls -l " + shellWord(directory.path) }

  func check(expectedDay: String?) -> DoctorCheck {
    if expectedDay == "" {
      return DoctorCheck(
        id: "data.backup", status: .pass,
        message: "No daily backup yet; the first write creates one.")
    }
    guard readable else {
      return DoctorCheck(
        id: "data.backup", status: .warning,
        message: "Backup files could not be listed; coverage is unknown.", next: [listing])
    }
    guard let expectedDay else {
      return DoctorCheck(
        id: "data.backup", status: .warning,
        message:
          "\(count) published backup(s) available; write coverage is unknown. Restore is the human's decision.",
        next: count > 0 ? [listing] : [])
    }
    let covered = Self.validDay(expectedDay) && days.contains(expectedDay)
    return DoctorCheck(
      id: "data.backup", status: covered ? .pass : .warning,
      message: covered
        ? "The recorded daily backup is present."
        : "The recorded daily backup is missing or invalid.",
      next: covered ? [] : [listing])
  }

  private static func validDay(_ day: String) -> Bool {
    do {
      let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(
        day + "T00:00:00.000Z")
      return utcDay(date) == day
    } catch { return false }
  }
}
