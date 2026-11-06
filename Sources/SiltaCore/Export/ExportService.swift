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
  /// The new commit, absent when no commit was made.
  package var sha: String?
  /// Work directories left for the human, with why. Reported as warnings, not data.
  package var leftovers: [ExportLeftover] = []
  /// Git coverage warnings, reported alongside leftovers.
  package var gitWarnings: [OutputWarning] = []

  enum CodingKeys: String, CodingKey { case workspace, path, files, sha }
}

/// A directory export left for the human to look at, and why.
package struct ExportLeftover: Equatable, Sendable {
  /// The directory.
  package let path: String
  /// Why it is there, as a clause after the path.
  package let reason: String

  /// The `export_leftover` warning that names it.
  package var warning: OutputWarning {
    OutputWarning(
      code: "export_leftover", message: "\(path) \(reason); ask the human before deleting it.")
  }
}

/// An export error that also reports leftover directories.
package struct ExportFailure: WarnedFailure, Equatable {
  /// The error itself.
  package let error: ExportError
  /// The leftovers to report with it.
  package let leftovers: [ExportLeftover]

  /// The error's code.
  package var code: ErrorCode { error.code }
  /// The error's message.
  package var message: String { error.message }
  /// The error's next commands.
  package var next: [String] { error.next }
  /// Who acts on them.
  package var nextBy: NextBy { error.nextBy }
  /// One `export_leftover` warning per leftover.
  package var warnings: [OutputWarning] { leftovers.map(\.warning) }
}

/// The two moves export makes, so a test can stand in for a volume without an atomic
/// swap. Both return 0 or -1 with `errno` set, like the system calls.
struct ExportMoves: Sendable {
  var swap: @Sendable (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_SWAP)) }
  var rename: @Sendable (String, String) -> Int32 = { Darwin.rename($0, $1) }
  var sync: @Sendable (URL) throws -> Void = { try ExportDurability.sync($0) }
}

/// Writes export trees to disk (spec §15).
package enum ExportService {
  /// Writes `<root>/<workspace>` from one read transaction. The target must be absent,
  /// empty or a previous export, and outside every registered repo; it is replaced by
  /// a staged tree in one swap, under a lock in `home` that serialises exports. Throws
  /// `ExportError`, `StorageError` or `WorkspaceError`; publication errors name retained recovery data.
  package static func export(
    workspace slug: String, to root: URL, store: DatabaseStore, home: URL,
    clock: any Clock = SystemClock()
  ) throws -> ExportResult {
    try store.initialize()
    let lock = try exportLock(home: home, clock: clock)
    defer { withExtendedLifetime(lock) {} }
    return try write(workspace: slug, to: root, store: store, moves: ExportMoves())
  }

  static func export(
    workspace slug: String, to root: URL, store: DatabaseStore, home: URL, moves: ExportMoves
  ) throws -> ExportResult {
    try store.initialize()
    let lock = try exportLock(home: home, clock: SystemClock())
    defer { withExtendedLifetime(lock) {} }
    return try write(workspace: slug, to: root, store: store, moves: moves)
  }

  static func exportLock(home: URL, clock: any Clock) throws -> BoundedFileLock {
    do {
      return try BoundedFileLock(home.appending(path: "export.lock"), clock: clock)
    } catch StorageError.busy { throw ExportError.busy }
  }

  /// The caller holds the export lock, including through any Git operation.
  static func write(
    workspace slug: String, to root: URL, store: DatabaseStore, moves: ExportMoves
  ) throws -> ExportResult {
    let root = root.standardizedFileURL
    let target = root.appending(path: slug, directoryHint: .isDirectory)
    let failed = ExportError.unwritable(path: root.path, workspace: slug)
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
    let prefix = ".\(slug).export-"
    let crashed = leftovers(in: root, prefix: prefix)
    // A failure still reports the leftovers the human may need to look at.
    func failing(_ error: ExportError) -> any Error {
      crashed.isEmpty ? error : ExportFailure(error: error, leftovers: crashed)
    }
    let kept: [ExportLeftover]
    do {
      try checkTarget(target, workspace: slug)
      try ExportDurability.syncAncestors(of: root, moves: moves)
      kept = try publish(files, to: target, prefix: prefix, workspace: slug, moves: moves)
    } catch let error as ExportError {
      if case .publicationUnconfirmed(_, let work) = error {
        throw ExportFailure(
          error: error,
          leftovers: crashed + [
            ExportLeftover(
              path: work, reason: "was retained after a publication flush failed")
          ])
      }
      throw failing(error)
    } catch {
      throw failing(failed)
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
  ) throws -> [ExportLeftover] {
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
      try ExportDurability.stage(files, tree: staging, moves: moves)
    } catch {
      discard()
      throw error
    }
    guard fm.fileExists(atPath: target.path) else {
      guard moves.rename(staging.path, target.path) == 0 else {
        discard()
        throw SwapFailure()
      }
      return try finish(work, replaced: nil, target: target, workspace: workspace, moves: moves)
    }
    if moves.swap(staging.path, target.path) == 0 {
      return try finish(work, replaced: staging, target: target, workspace: workspace, moves: moves)
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
    return try finish(work, replaced: previous, target: target, workspace: workspace, moves: moves)
  }

  private static func finish(
    _ work: URL, replaced: URL?, target: URL, workspace: String, moves: ExportMoves
  ) throws -> [ExportLeftover] {
    do {
      try moves.sync(work)
      try moves.sync(target.deletingLastPathComponent())
    } catch {
      throw ExportError.publicationUnconfirmed(path: target.path, kept: work.path)
    }
    return retire(work, replaced: replaced, workspace: workspace)
  }

  /// Removes the work directory once the tree it holds is export's own, checked again
  /// now, since files can appear in the target while the new tree is written. Otherwise
  /// the directory stays and is returned, as is one that could not be removed.
  private static func retire(_ work: URL, replaced: URL?, workspace: String) -> [ExportLeftover] {
    if let replaced {
      do { try checkTarget(replaced, workspace: workspace) } catch {
        var problem = "something export did not write"
        if case ExportError.notAnExport(_, let entry, _)? = error as? ExportError {
          problem =
            entry.hasPrefix("it holds ") ? String(entry.dropFirst("it holds ".count)) : entry
        }
        let reason =
          "holds the replaced tree in \(replaced.lastPathComponent)/, with \(problem), "
          + "which export did not write"
        return [ExportLeftover(path: work.path, reason: reason)]
      }
    }
    do {
      try FileManager.default.removeItem(at: work)
      return []
    } catch {
      return [ExportLeftover(path: work.path, reason: "could not be removed")]
    }
  }

  /// Work directories an earlier export left under `root`; a root that can't be listed
  /// is reported itself, since it may hold some.
  private static func leftovers(in root: URL, prefix: String) -> [ExportLeftover] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)  // reported
    else {
      return [ExportLeftover(path: root.path, reason: "could not be listed for work directories")]
    }
    return names.filter { $0.hasPrefix(prefix) }.sorted().map {
      ExportLeftover(
        path: root.appending(path: $0).path, reason: "was left by an export that did not finish")
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
      throw refused("it is a file, not a directory")
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
    guard let found else { throw refused("it can't be read") }
    var present: Set<String> = []
    for case let url as URL in found {
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])  // nil: a file
      let directory = values?.isDirectory
      let path = url.standardizedFileURL.path
      let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
      if directory != true && url.lastPathComponent != ".DS_Store" { present.insert(relative) }
    }
    if let unreadable {
      throw refused(
        unreadable == base ? "it can't be read" : "it holds an entry it can't read (\(unreadable))")
    }
    guard let first = present.min(by: ExportSnapshot.byteOrder) else { return }
    let manifestPath = target.appending(path: ExportFormat.manifestFile).path
    let data = FileManager.default.contents(atPath: manifestPath)
    if data == nil, present.contains(ExportFormat.manifestFile) {
      throw refused("its manifest.json can't be read")
    }
    let manifest = try? ExportManifest(data)  // nil: not an export, refused below
    guard let manifest, manifest.workspace == workspace else { throw refused("it holds \(first)") }
    let listed = Set(manifest.files.keys).union([ExportFormat.manifestFile])
    if let extra = present.subtracting(listed).min(by: ExportSnapshot.byteOrder) {
      throw refused("it holds \(extra)")
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
