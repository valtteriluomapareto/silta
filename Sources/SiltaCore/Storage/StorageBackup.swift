import Darwin
import Foundation
import GRDB

/// Fixed-location complete snapshots. Publication never replaces an existing backup.
struct StorageBackup {
  let home: URL
  private let file: DatabaseFile?
  private static let pendingLeaf = "snapshot.pending"

  init(home: URL, file: DatabaseFile? = nil) {
    self.home = DirectoryPath.canonicalHome(home)
    self.file = file
  }

  /// Daily and pre-migration snapshots stage under fixed names protected by their
  /// caller's write or migration lock. Manual snapshots have a private work directory.
  func snapshot(
    name: String, reuseExisting: Bool = false, staging: String? = nil,
    source: DatabaseQueue? = nil, openedStage: Int32? = nil
  ) throws -> URL {
    let parent = try DirectoryPath.open(home)
    defer { close(parent) }
    let directory = try backupDirectory(in: parent)
    defer { close(directory) }
    let nameInHome = staging ?? (reuseExisting ? "daily.pending" : "migration.pending")
    let fixed = openedStage == nil
    let work = fixed ? ".backup-" + nameInHome : nameInHome
    let stage = try openedStage ?? DirectoryPath.open(work, in: parent, creating: true)
    defer { if fixed { close(stage) } }
    try requirePrivateStage(stage)
    let leaf = Self.pendingLeaf
    let namedStage = home.appending(path: work)
    let namedDestination = home.appending(path: "backups")
    try Self.requireAttached(stage, path: namedStage)
    defer {
      _ = unlinkat(stage, leaf, 0)
      if fixed, DirectoryPath.matches(parent, path: home),
        DirectoryPath.matches(stage, path: namedStage)
      {
        _ = unlinkat(parent, work, AT_REMOVEDIR)
      }
    }
    if fixed {
      _ = unlinkat(directory, nameInHome, 0)
      _ = unlinkat(stage, leaf, 0)
    }
    try Self.requireAttached(stage, path: namedStage)
    try copy(to: namedStage.appending(path: leaf), source: source)
    let snapshot = try Self.preparedSnapshot(in: stage)
    defer { close(snapshot) }
    try Self.requireAttached(stage, path: namedStage)
    try Self.requireAttached(directory, path: namedDestination)
    try file?.requireCurrent(at: sourceEntry)
    let failure = try Self.publish(name, in: directory, work: work, staged: (stage, snapshot))
    guard
      failure == 0
        || (reuseExisting && failure == EEXIST && (Self.regularSize(name, in: directory) ?? 0) > 0)
    else {
      if failure == EEXIST { throw BackupFailure.occupied }
      throw BackupFailure.filesystem(StorageError.fileFailure(failure, at: home.path))
    }
    try Self.requireAttached(directory, path: namedDestination)
    return namedDestination.appending(path: name)
  }

  func hasPublishedSnapshot(named name: String) -> Bool {
    do {
      let directory = try DirectoryPath.open(home.appending(path: "backups"))
      defer { close(directory) }
      return (Self.regularSize(name, in: directory) ?? 0) > 0
    } catch { return false }
  }

  private var sourceEntry: String { home.appending(path: "silta.db").path }

  private func backupDirectory(in parent: Int32) throws -> Int32 {
    do {
      return try DirectoryPath.open("backups", in: parent, creating: true)
    } catch {
      throw BackupFailure.destination
    }
  }

  private func requirePrivateStage(_ stage: Int32) throws {
    var info = stat()
    guard fstat(stage, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else { throw BackupFailure.staging }
  }

  static func requireAttached(_ descriptor: Int32, path: URL) throws {
    guard DirectoryPath.matches(descriptor, path: path) else { throw BackupFailure.detached }
  }

  private static func preparedSnapshot(in stage: Int32) throws -> Int32 {
    let file = openat(stage, pendingLeaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard file >= 0 else { throw BackupFailure.staging }
    var info = stat()
    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
      fchmod(file, 0o600) == 0, fcntl(file, F_FULLFSYNC) == 0 || fsync(file) == 0
    else {
      close(file)
      throw BackupFailure.staging
    }
    return file
  }

  /// A mounted backups directory needs a private same-volume copy before publication.
  private static func publish(
    _ name: String, in backups: Int32, work: String,
    staged: (directory: Int32, file: Int32)
  ) throws -> Int32 {
    let leaf = pendingLeaf
    if linkat(staged.directory, leaf, backups, name, 0) == 0 { return 0 }
    guard errno == EXDEV else { return errno }
    let transfer = try DirectoryPath.open(work, in: backups, creating: true)
    defer {
      close(transfer)
      _ = unlinkat(backups, work, AT_REMOVEDIR)
    }
    _ = unlinkat(transfer, leaf, 0)
    let file = openat(
      transfer, leaf, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw transferFailure(errno) }
    defer {
      close(file)
      _ = unlinkat(transfer, leaf, 0)
    }
    guard fcopyfile(staged.file, file, nil, UInt32(COPYFILE_DATA)) == 0 else {
      throw transferFailure(errno)
    }
    guard fcntl(file, F_FULLFSYNC) == 0 || fsync(file) == 0 else { throw transferFailure(errno) }
    return linkat(transfer, leaf, backups, name, 0) == 0 ? 0 : errno
  }

  private static func transferFailure(_ code: Int32) -> BackupFailure {
    BackupFailure.filesystem(StorageError.fileFailure(code, at: ""))
  }

  private func copy(to temporary: URL, source: DatabaseQueue?) throws {
    let target = try file ?? DatabaseFile(at: sourceEntry)
    try target.requireCurrent(at: sourceEntry)
    var config = Configuration()
    // A writer already holds the WAL coordination files for transaction-side snapshots.
    config.readonly = file != nil
    config.busyMode = .timeout(5)
    do {
      let source = try source ?? DatabaseQueue(path: target.path, configuration: config)
      try source.writeWithoutTransaction { db in
        try target.requireCurrent(at: sourceEntry)
        try db.execute(sql: "VACUUM INTO ?", arguments: [temporary.path])
        try target.requireCurrent(at: sourceEntry)
      }
    } catch let error as StorageError where error == .databaseReplaced {
      throw error
    } catch {
      let cause = StorageError.mapped(error, at: target.path)
      throw BackupFailure.filesystem(cause)
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
