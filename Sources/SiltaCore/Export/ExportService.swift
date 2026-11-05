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
  /// Work directories left for the human: a crashed export's, or one kept because the
  /// replaced tree held files export did not write. Reported as warnings, not data.
  package var leftovers: [String] = []

  enum CodingKeys: String, CodingKey { case workspace, path, files }
}

/// The two moves export makes, so a test can stand in for a volume without an atomic
/// swap. Both return 0 or -1 with `errno` set, like the system calls.
struct ExportMoves: Sendable {
  var swap: @Sendable (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_SWAP)) }
  var rename: @Sendable (String, String) -> Int32 = { Darwin.rename($0, $1) }
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
    try export(workspace: slug, to: root, store: store, home: home, moves: ExportMoves())
  }

  static func export(
    workspace slug: String, to root: URL, store: DatabaseStore, home: URL, moves: ExportMoves
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
    let prefix = ".\(slug).export-"
    let crashed = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])  // none
      .filter { $0.hasPrefix(prefix) }.sorted().map { root.appending(path: $0).path }
    let kept: [String]
    do {
      kept = try publish(files, to: target, prefix: prefix, workspace: slug, moves: moves)
    } catch let error as ExportError {
      throw error
    } catch {
      throw failed
    }
    var result = ExportResult(workspace: slug, path: target.path, files: files.count)
    result.leftovers = crashed + kept
    return result
  }

  /// Writes `files` into a work directory of its own next to `target`, created with a
  /// unique name, then swaps the tree in; the replaced tree goes with the work directory
  /// when it is export's own, and the work directory is returned for a warning when it
  /// isn't. Nothing else is removed. A volume without an atomic swap (exFAT, SMB) moves
  /// the previous tree aside first and puts it back on failure; when even that fails,
  /// the work directory is kept and `previousKept` names it.
  static func publish(
    _ files: [String: Data], to target: URL, prefix: String, workspace: String,
    moves: ExportMoves
  ) throws -> [String] {
    let fm = FileManager.default
    let work = try ownDirectory(in: target.deletingLastPathComponent(), prefix: prefix)
    let staging = work.appending(path: "tree")
    let previous = work.appending(path: "previous")
    func discard() { try? fm.removeItem(at: work) }  // best-effort: only this run's directory
    do {
      for (path, data) in files {
        let file = staging.appending(path: path)
        try fm.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
      }
    } catch {
      discard()
      throw error
    }
    guard fm.fileExists(atPath: target.path) else {
      guard moves.rename(staging.path, target.path) == 0 else {
        discard()
        throw SwapFailure()
      }
      return retire(work, replaced: nil, workspace: workspace)
    }
    if moves.swap(staging.path, target.path) == 0 {
      return retire(work, replaced: staging, workspace: workspace)
    }
    guard errno == ENOTSUP || errno == EINVAL, moves.rename(target.path, previous.path) == 0 else {
      discard()
      throw SwapFailure()
    }
    guard moves.rename(staging.path, target.path) == 0 else {
      guard moves.rename(previous.path, target.path) == 0 else {
        throw ExportError.previousKept(
          path: previous.path, target: target.path, workspace: workspace)
      }
      discard()
      throw SwapFailure()
    }
    return retire(work, replaced: previous, workspace: workspace)
  }

  /// Removes the work directory once the tree it holds is export's own, checked again
  /// now, since files can appear in the target while the new tree is written. Otherwise
  /// the directory stays and is returned, as is one that could not be removed.
  private static func retire(_ work: URL, replaced: URL?, workspace: String) -> [String] {
    if let replaced {
      do { try checkTarget(replaced, workspace: workspace) } catch { return [work.path] }
    }
    do {
      try FileManager.default.removeItem(at: work)
      return []
    } catch {
      return [work.path]
    }
  }

  /// A new directory under `parent` that no one else has: `mkdtemp` creates it exclusively.
  static func ownDirectory(in parent: URL, prefix: String) throws -> URL {
    var template = Array(parent.appending(path: prefix + "XXXXXX").path.utf8CString)
    let created = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
    let bytes = template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    guard created != nil, let path = String(bytes: bytes, encoding: .utf8) else {
      throw SwapFailure()
    }
    return URL(filePath: path, directoryHint: .isDirectory)
  }

  private struct SwapFailure: Error {}  // guard:allow-error mapped to unwritable by export

  /// Refuses a target that isn't absent, empty or this workspace's previous export:
  /// a format 1 manifest for `workspace`, no file it doesn't list (`.DS_Store` aside)
  /// and nothing unreadable. Listed files may be missing; they are rewritten.
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
    // An entry that can't be read could hold anything, so it refuses rather than counts
    // as empty.
    var unreadable: String?
    let base = target.standardizedFileURL.path
    let found = FileManager.default.enumerator(
      at: target, includingPropertiesForKeys: [.isDirectoryKey], options: [],
      errorHandler: { url, _ in
        unreadable = unreadable ?? url.standardizedFileURL.path
        return false
      })
    guard let found else { throw refused("an entry it can't read (\(base))") }
    var present: Set<String> = []
    for case let url as URL in found {
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])  // nil: a file
      let directory = values?.isDirectory
      let path = url.standardizedFileURL.path
      let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
      if directory != true && url.lastPathComponent != ".DS_Store" { present.insert(relative) }
    }
    if let unreadable { throw refused("an entry it can't read (\(unreadable))") }
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
