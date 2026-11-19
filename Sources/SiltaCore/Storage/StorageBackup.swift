import Darwin
import Foundation
import GRDB

/// Fixed-location complete snapshots. Publication never replaces an existing backup.
struct StorageBackup {
  let home: URL

  init(home: URL) {
    self.home = DirectoryPath.canonicalHome(home)
  }

  /// Daily and pre-migration snapshots stage under fixed names protected by their
  /// caller's write or migration lock. Manual snapshots have a private work directory.
  func snapshot(name: String, reuseExisting: Bool = false, staging: String? = nil) throws -> URL {
    do {
      let parent = try DirectoryPath.open(home)
      defer { close(parent) }
      let directory = try DirectoryPath.open("backups", in: parent, creating: true)
      defer { close(directory) }
      let nameInHome = staging ?? (reuseExisting ? "daily.pending" : "migration.pending")
      let fixed = !nameInHome.hasPrefix(".manual-")
      let work = fixed ? ".backup-" + nameInHome : nameInHome
      let stage = try DirectoryPath.open(work, in: parent, creating: fixed)
      defer { close(stage) }
      var info = stat()
      guard fstat(stage, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
      else { throw StorageError.backupFailed }
      let leaf = "snapshot.pending"
      defer {
        _ = unlinkat(stage, leaf, 0)
        if fixed { _ = unlinkat(parent, work, AT_REMOVEDIR) }
      }
      if fixed {
        // Clear the previous staging name, including one left by an older writer.
        _ = unlinkat(directory, nameInHome, 0)
        _ = unlinkat(stage, leaf, 0)
      }
      try copy(to: home.appending(path: work).appending(path: leaf))
      let file = openat(stage, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard file >= 0 else { throw StorageError.backupFailed }
      defer { close(file) }
      guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
        fchmod(file, 0o600) == 0, fcntl(file, F_FULLFSYNC) == 0 || fsync(file) == 0
      else { throw StorageError.backupFailed }
      if linkat(stage, leaf, directory, name, 0) != 0 {
        guard reuseExisting, errno == EEXIST, Self.regularSize(name, in: directory) != nil else {
          throw StorageError.backupFailed
        }
      }
      return home.appending(path: "backups").appending(path: name)
    } catch {
      throw StorageError.backupFailed
    }
  }

  private func copy(to temporary: URL) throws {
    // Keep SQLite's named destination in the home, independent of the backups entry.
    // A read-write connection can initialize WAL sidecars while reading committed state.
    var config = Configuration()
    config.busyMode = .timeout(5)
    let source = try DatabaseQueue(
      path: home.appending(path: "silta.db").path, configuration: config)
    try source.writeWithoutTransaction { db in
      try db.execute(sql: "VACUUM INTO ?", arguments: [temporary.path])
    }
  }

  func prune(on day: String, manual: Bool = false, keeping: Set<String> = []) throws {
    let directory = try DirectoryPath.open(home.appending(path: "backups"))
    defer { close(directory) }
    let files = try DirectoryPath.names(in: directory).compactMap { name -> (String, Bool)? in
      guard let date = Self.day(of: name, manual: manual),
        Self.regularSize(name, in: directory) != nil
      else { return nil }
      return (name, Self.validDay(date) && date <= day)
    }
    let unprotected = files.filter { !keeping.contains($0.0) }.sorted { a, b in
      a.1 == b.1 ? a.0 < b.0 : !a.1
    }
    let slots = 7 - (files.count - unprotected.count)
    for (name, _) in unprotected.dropLast(slots) {
      guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else {
        throw StorageError.backupFailed
      }
    }
  }

  static func day(of name: String, manual: Bool) -> String? {
    let recognized =
      manual
      ? name.wholeMatch(of: /silta-[0-9]{4}-[0-9]{2}-[0-9]{2}-manual-[0-9]+-[A-Za-z0-9]{6}\.db/)
        != nil
      : name.wholeMatch(of: /silta-[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-before-[A-Za-z0-9]+-[0-9]+)?\.db/)
        != nil
    return recognized ? String(name.dropFirst(6).prefix(10)) : nil
  }

  static func validDay(_ day: String) -> Bool {
    do {
      let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(
        day + "T00:00:00.000Z")
      return utcDay(date) == day
    } catch { return false }
  }

  static func regularSize(_ name: String, in directory: Int32) -> off_t? {
    var file = stat()
    guard fstatat(directory, name, &file, AT_SYMLINK_NOFOLLOW) == 0,
      file.st_mode & S_IFMT == S_IFREG
    else { return nil }
    return file.st_size
  }
}
