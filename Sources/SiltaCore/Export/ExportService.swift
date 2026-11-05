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
  /// empty or a previous export, and outside every registered repo; it is replaced by
  /// a staged tree in one swap, under a lock in `home` that serialises exports. Throws
  /// `ExportError`, `StorageError` or `WorkspaceError`; on failure the target is as it was.
  package static func export(
    workspace slug: String, to root: URL, store: DatabaseStore, home: URL
  ) throws -> ExportResult {
    try store.initialize()
    let root = root.standardizedFileURL
    let target = root.appending(path: slug, directoryHint: .isDirectory)
    let failed = ExportError.unwritable(path: root.path, workspace: slug)
    // Locked before the read, so a later export always publishes a later state.
    let lock = Darwin.open(home.appending(path: "export.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw failed }
    defer { close(lock) }
    guard flock(lock, LOCK_EX) == 0 else { throw failed }
    defer { flock(lock, LOCK_UN) }
    let (files, repos) = try store.read { db in
      (
        try ExportTree.render(db, workspace: slug),
        try Row.fetchAll(
          db,
          sql: "SELECT r.slug, p.path FROM repo_path p JOIN repo r ON r.id=p.repo_id ORDER BY r.id")
      )
    }
    let planned = try canonical(target, failed: failed)
    for repo in repos {
      let path = URL(filePath: repo["path"])
      if LocationPath.contains(path, planned) || LocationPath.contains(planned, path) {
        throw ExportError.insideRepo(path: target.path, repo: repo["slug"], workspace: slug)
      }
    }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
      throw failed
    }
    try checkTarget(target, workspace: slug)
    do {
      try publish(files, to: target, prefix: ".\(slug).export-")
    } catch {
      throw failed
    }
    return ExportResult(workspace: slug, path: target.path, files: files.count)
  }

  /// Writes `files` into a work directory of its own next to `target`, created with a
  /// unique name, then swaps the tree in; the previous tree goes with the work directory.
  /// Nothing else is removed. A volume without an atomic swap (exFAT, SMB) moves the
  /// previous tree aside first and puts it back on failure.
  private static func publish(_ files: [String: Data], to target: URL, prefix: String) throws {
    let fm = FileManager.default
    let work = try ownDirectory(in: target.deletingLastPathComponent(), prefix: prefix)
    defer { try? fm.removeItem(at: work) }  // best-effort cleanup of this run's own directory
    let staging = work.appending(path: "tree")
    let previous = work.appending(path: "previous")
    for (path, data) in files {
      let file = staging.appending(path: path)
      try fm.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: file)
    }
    if !fm.fileExists(atPath: target.path) {
      guard rename(staging.path, target.path) == 0 else { throw SwapFailure() }
    } else if renamex_np(staging.path, target.path, UInt32(RENAME_SWAP)) != 0 {
      guard errno == ENOTSUP || errno == EINVAL, rename(target.path, previous.path) == 0 else {
        throw SwapFailure()
      }
      guard rename(staging.path, target.path) == 0 else {
        _ = rename(previous.path, target.path)
        throw SwapFailure()
      }
    }
  }

  /// A new directory under `parent` that no one else has: `mkdtemp` creates it exclusively.
  private static func ownDirectory(in parent: URL, prefix: String) throws -> URL {
    var template = Array(parent.appending(path: prefix + "XXXXXX").path.utf8CString)
    let created = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
    guard created != nil else { throw SwapFailure() }
    let path = String(
      decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return URL(filePath: path, directoryHint: .isDirectory)
  }

  private struct SwapFailure: Error {}  // guard:allow-error mapped to unwritable by export

  /// Refuses a target that isn't absent, empty or this workspace's previous export:
  /// a format 1 manifest for `workspace` and no file it doesn't list (`.DS_Store`
  /// aside). Listed files may be missing; they are rewritten.
  private static func checkTarget(_ target: URL, workspace: String) throws {
    let refused = { (entry: String) in
      ExportError.notAnExport(path: target.path, entry: entry, workspace: workspace)
    }
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    let values = try? target.resourceValues(forKeys: keys)  // nil: absent
    guard let values else { return }
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw refused("a file, not a directory")
    }
    var present: Set<String> = []
    if let enumerator = FileManager.default.enumerator(atPath: target.path) {
      for case let path as String in enumerator
      where enumerator.fileAttributes?[.type] as? FileAttributeType != .typeDirectory
        && URL(filePath: path).lastPathComponent != ".DS_Store"
      {
        present.insert(path)
      }
    }
    guard let first = present.min(by: ExportSnapshot.byteOrder) else { return }
    let data = FileManager.default.contents(
      atPath: target.appending(path: ExportFormat.manifestFile).path)
    let manifest = try? ExportManifest(data)  // nil: not an export, refused below
    guard let manifest, manifest.workspace == workspace else { throw refused(first) }
    let listed = Set(manifest.files.keys).union([ExportFormat.manifestFile])
    if let extra = present.subtracting(listed).min(by: ExportSnapshot.byteOrder) {
      throw refused(extra)
    }
  }

  /// The canonical form of `url`, whose tail may not exist yet, comparable with the
  /// canonical repo paths.
  private static func canonical(_ url: URL, failed: ExportError) throws -> URL {
    var existing = url
    var tail: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
      tail.insert(existing.lastPathComponent, at: 0)
      existing = existing.deletingLastPathComponent()
    }
    let base: URL
    do { base = try LocationPath.canonical(existing) } catch { throw failed }
    let caseKey: Set<URLResourceKey> = [.volumeSupportsCaseSensitiveNamesKey]
    let volume = try? existing.resourceValues(forKeys: caseKey)  // unknown: as written
    let folded = volume?.volumeSupportsCaseSensitiveNames == false
    return tail.reduce(base) { $0.appending(path: folded ? $1.lowercased() : $1) }
  }
}
