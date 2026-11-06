package import Foundation

extension ExportService {
  /// Exports and commits only the workspace subtree. Git preflight precedes writing;
  /// later failures explicitly preserve the written tree and a safe retry command.
  package static func commit(
    workspace: String, to root: URL, store: DatabaseStore, home: URL,
    seams: (git: any GitRunner, clock: any Clock)
  ) async throws -> ExportResult {
    let root = root.standardizedFileURL
    let operation = ExportCommit(root: root, workspace: workspace, git: seams.git)
    try await operation.preflight()
    try store.initialize()
    let lock = try exportLock(home: home, clock: seams.clock)
    defer { withExtendedLifetime(lock) {} }
    let result = try write(workspace: workspace, to: root, store: store, moves: ExportMoves())
    return try await operation.commit(result)
  }
}

/// Git operations for one export root, with warnings retained on every post-write failure.
private struct ExportCommit {
  let root: URL
  let workspace: String
  let git: any GitRunner

  var failed: ExportError { .gitFailed(root: root.path, workspace: workspace) }

  func run(_ arguments: [String]) async throws -> GitResult {
    try await git.run(.init(arguments: arguments, directory: root))
  }

  func preflight() async throws {
    do {
      let result = try await run(["rev-parse", "--is-inside-work-tree"])
      guard result.termination == .exit(0),
        String(bytes: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .newlines) == "true"
      else { throw failed }
    } catch { throw ExportError.notWorkTree(root: root.path) }
  }

  func commit(_ written: ExportResult) async throws -> ExportResult {
    var result = written
    var warnings = result.leftovers.map(\.warning)
    do {
      let manifest = try ExportManifest(
        Data(contentsOf: root.appending(path: workspace + "/manifest.json")))
      let paths = (Array(manifest.files.keys) + [ExportFormat.manifestFile]).sorted().map {
        workspace + "/" + $0
      }
      let ignored = try await ignoredPaths(paths)
      if !ignored.isEmpty {
        let warning = OutputWarning(
          code: "export_ignored",
          message: "Git ignores exported files: " + ignored.joined(separator: ", ")
            + ". The disk tree is complete; these paths are not covered by the commit.")
        result.gitWarnings.append(warning)
        warnings.append(warning)
      }
      try await stage(allIgnored: ignored.count == paths.count)
      let changed = try await run(["diff", "--cached", "--quiet", "--", workspace])
      if changed.termination == .exit(0) { return result }
      guard changed.termination == .exit(1) else { throw failed }
      let committed = try await run(["commit", "-m", "Export " + workspace, "--", workspace])
      guard committed.termination == .exit(0) else { throw failed }
      let head = try await run(["rev-parse", "--verify", "HEAD"])
      guard head.termination == .exit(0), let text = String(bytes: head.stdout, encoding: .utf8)
      else { throw failed }
      let sha = text.trimmingCharacters(in: .newlines)
      guard sha.wholeMatch(of: /[a-f0-9]{40}|[a-f0-9]{64}/) != nil else { throw failed }
      result.sha = sha
      return result
    } catch {
      // No child output is echoed: hooks can print arbitrary workspace bodies.
      throw ExportGitFailure(failure: failed, warnings: warnings)
    }
  }

  func ignoredPaths(_ paths: [String]) async throws -> [String] {
    var ignored: [String] = []
    for offset in stride(from: 0, to: paths.count, by: 100) {
      let batch = paths[offset..<min(offset + 100, paths.count)]
      let result = try await run(["check-ignore", "--"] + batch)
      guard result.termination == .exit(0) || result.termination == .exit(1),
        let text = String(bytes: result.stdout, encoding: .utf8)
      else { throw failed }
      ignored += text.split(separator: "\n").map(String.init)
    }
    return ignored.sorted()
  }

  func stage(allIgnored: Bool) async throws {
    let added = try await run(["add", "-A", "--", workspace])
    if added.termination == .exit(0) { return }
    guard added.termination == .exit(1) else { throw failed }
    if allIgnored { return }
    // Git reports an ignored directory even while updating its tracked descendants.
    let rootIgnored = try await run(["check-ignore", "--no-index", "--", workspace])
    guard rootIgnored.termination == .exit(0) else { throw failed }
    let updated = try await run(["add", "-u", "--", workspace])
    guard updated.termination == .exit(0) else { throw failed }
  }
}

/// Retains export coverage warnings on a Git failure.
package struct ExportGitFailure: WarnedFailure {
  let failure: ExportError
  package let warnings: [OutputWarning]
  package var code: ErrorCode { failure.code }
  package var message: String { failure.message }
  package var next: [String] { failure.next }
  package var nextBy: NextBy { failure.nextBy }
}
