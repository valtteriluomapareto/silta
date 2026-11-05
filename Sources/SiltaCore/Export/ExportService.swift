import Darwin
package import Foundation
import GRDB

/// What an export wrote.
package struct ExportResult: Encodable, Sendable {
  /// The workspace slug.
  package let workspace: String
  /// The absolute path of the written tree, `<root>/<workspace>`.
  package let path: String
  /// The number of files in the tree, the manifest included.
  package let files: Int
}

/// Writes export trees to disk (spec §15).
package enum ExportService {
  /// Writes `<root>/<workspace>` from one read transaction. The target must be absent,
  /// empty or a previous export; it is replaced by a staged tree in one swap, under a
  /// lock in `home` that serialises exports. Throws `ExportError`, `StorageError` or
  /// `WorkspaceError`; on failure the target is as it was.
  package static func export(
    workspace slug: String, to root: URL, store: DatabaseStore, home: URL
  ) throws -> ExportResult {
    try store.initialize()
    let root = root.standardizedFileURL
    let (files, repos) = try store.read { db in
      (
        try ExportTree.render(db, workspace: slug),
        try Row.fetchAll(
          db,
          sql: "SELECT r.slug, p.path FROM repo_path p JOIN repo r ON r.id=p.repo_id ORDER BY r.id")
      )
    }
    let planned = try canonical(root)
    for repo in repos where LocationPath.contains(URL(filePath: repo["path"]), planned) {
      throw ExportError.insideRepo(path: root.path, repo: repo["slug"])
    }
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
      throw ExportError.unwritable(path: root.path)
    }
    let lock = Darwin.open(home.appending(path: "export.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw ExportError.unwritable(path: root.path) }
    defer { close(lock) }
    guard flock(lock, LOCK_EX) == 0 else { throw ExportError.unwritable(path: root.path) }
    defer { flock(lock, LOCK_UN) }
    let target = root.appending(path: slug, directoryHint: .isDirectory)
    try checkTarget(target)
    try publish(files, to: target, staging: root.appending(path: ".\(slug).staging"))
    return ExportResult(workspace: slug, path: target.path, files: files.count)
  }

  /// Writes `files` into a fresh staging directory next to `target`, then swaps it in;
  /// the previous tree, if any, is removed afterwards.
  private static func publish(_ files: [String: Data], to target: URL, staging: URL) throws {
    let fm = FileManager.default
    let root = target.deletingLastPathComponent()
    do {
      if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
      for (path, data) in files {
        let file = staging.appending(path: path)
        try fm.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
      }
      let swapped =
        fm.fileExists(atPath: target.path)
        ? renamex_np(staging.path, target.path, UInt32(RENAME_SWAP))
        : rename(staging.path, target.path)
      guard swapped == 0 else { throw ExportError.unwritable(path: root.path) }
    } catch {
      try? fm.removeItem(at: staging)  // best-effort cleanup; the target is untouched
      throw ExportError.unwritable(path: root.path)
    }
    // The staging directory now holds the previous tree; a leftover is replaced next time.
    try? fm.removeItem(at: staging)  // best-effort cleanup
  }

  /// Refuses a target that isn't absent, empty or exactly a previous export.
  private static func checkTarget(_ target: URL) throws {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    let values = try? target.resourceValues(forKeys: keys)  // nil: absent
    guard let values else { return }
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw ExportError.notAnExport(path: target.path, entry: target.lastPathComponent)
    }
    var present: Set<String> = []
    if let enumerator = fm.enumerator(atPath: target.path) {
      for case let path as String in enumerator
      where enumerator.fileAttributes?[.type] as? FileAttributeType != .typeDirectory
        && URL(filePath: path).lastPathComponent != ".DS_Store"
      {
        present.insert(path)
      }
    }
    guard !present.isEmpty else { return }
    let first = { (paths: Set<String>) in paths.sorted(by: ExportSnapshot.byteOrder).first }
    let manifest = fm.contents(atPath: target.appending(path: ExportFormat.manifestFile).path)
    guard
      let manifest,
      let parsed = try? JSONSerialization.jsonObject(with: manifest),  // refused below
      let object = parsed as? [String: Any],
      object["format"] is String, let list = object["files"] as? [[String: String]]
    else {
      throw ExportError.notAnExport(path: target.path, entry: first(present) ?? "")
    }
    let listed = Set(list.compactMap { $0["path"] }).union([ExportFormat.manifestFile])
    if let extra = first(present.subtracting(listed)) {
      throw ExportError.notAnExport(path: target.path, entry: extra)
    }
    if let missing = first(listed.subtracting(present)) {
      throw ExportError.notAnExport(path: target.path, entry: "no \(missing)")
    }
  }

  /// The canonical form of `url`, whose tail may not exist yet, comparable with the
  /// canonical repo paths.
  private static func canonical(_ url: URL) throws -> URL {
    var existing = url
    var tail: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
      tail.insert(existing.lastPathComponent, at: 0)
      existing = existing.deletingLastPathComponent()
    }
    let base: URL
    do { base = try LocationPath.canonical(existing) } catch {
      throw ExportError.unwritable(path: url.path)
    }
    let caseKey: Set<URLResourceKey> = [.volumeSupportsCaseSensitiveNamesKey]
    let volume = try? existing.resourceValues(forKeys: caseKey)  // unknown: as written
    let folded = volume?.volumeSupportsCaseSensitiveNames == false
    return tail.reduce(base) { $0.appending(path: folded ? $1.lowercased() : $1) }
  }
}
