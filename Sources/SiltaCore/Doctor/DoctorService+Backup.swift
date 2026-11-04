import Foundation

extension DoctorService {
  static func backup(_ home: URL, at now: Date) -> DoctorCheck {
    do {
      let files = try FileManager.default.contentsOfDirectory(
        at: home.appending(path: "backups"),
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      let days = try files.compactMap { file -> String? in
        let name = file.lastPathComponent
        guard name.wholeMatch(of: /silta-[0-9]{4}-[0-9]{2}-[0-9]{2}\.db/) != nil else { return nil }
        let values = try file.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          (values.fileSize ?? 0) > 0
        else { return nil }
        let day = String(name.dropFirst(6).prefix(10))
        do {
          let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(
            day + "T00:00:00.000Z")
          guard utcDay(date) == day, day <= utcDay(now) else { return nil }
        } catch { return nil }
        return day
      }
      guard let latest = days.max() else {
        return DoctorCheck(
          id: "data.backup", status: "warning",
          message: "No published daily backup is available.",
          next: ["/bin/ls -l " + shellWord(home.appending(path: "backups").path)])
      }
      let stale = latest < utcDay(now.addingTimeInterval(-86400))
      return DoctorCheck(
        id: "data.backup", status: stale ? "warning" : "pass",
        message: stale
          ? "Latest daily backup is older than one UTC day." : "A recent daily backup exists.",
        next: stale ? ["/bin/ls -l " + shellWord(home.appending(path: "backups").path)] : [])
    } catch {
      return DoctorCheck(
        id: "data.backup", status: "warning", message: "Daily backups could not be listed.",
        next: ["/bin/ls -l " + shellWord(home.appending(path: "backups").path)])
    }
  }
}
