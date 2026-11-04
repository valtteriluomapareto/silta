package import Foundation
import GRDB

/// Reads other apps through immutable git objects without checking out a branch.
package struct CodeService {
  private let workspace: String
  private let store: DatabaseStore
  private let git: any GitRunner
  private let date: Date

  /// Creates a reader with command-scoped storage, git and injected time.
  package init(workspace: String, store: DatabaseStore, git: any GitRunner, at date: Date) {
    self.workspace = workspace
    self.store = store
    self.git = git
    self.date = date
  }

  /// Resolves the selected commit once, optionally fetching first. Reads never update
  /// storage; only an explicitly requested successful fetch records its timestamp.
  package func read(
    _ operation: CodeRead, target: String, prod: Bool = false, fetch: Bool = false
  ) async throws -> CodeResult {
    try operation.validate()
    let parts = target.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = parts.first, !first.isEmpty,
      parts.count == 1 || (!parts[1].isEmpty && !prod), !target.contains("\0")
    else {
      throw CodeError.invalid(
        "Use app[@ref], or app with --prod.", command: "silta code \(operation.verb)")
    }
    let app = String(first)
    let selection = try select(app)
    try operation.validate(subpath: selection.subpath)
    let ref = parts.count == 2 ? String(parts[1]) : (prod ? selection.prod : selection.ref)
    let configuration = "silta --ws \(shellWord(workspace)) ws show"
    guard let ref else {
      throw CodeError.notFound(
        "App \(app.debugDescription) has no prod_ref.", next: [configuration])
    }
    if fetch {
      do {
        _ = try await RepositoryFetch.fetch(
          selection.repo, workspace: workspace, store: store, git: git, at: date)
      } catch RepoError.fetch {
        throw CodeError.fetch(
          repo: selection.repo,
          retry: operation.command(workspace: workspace, target: target, prod: prod))
      }
    }
    let sha = try await resolve(ref, app: app, selection: selection, operation: operation)
    let (output, warnings) = try await content(
      operation, sha: sha, selection: selection, target: app + "@" + ref)
    let immutable = [40, 64].contains(ref.count) && ref.allSatisfy(\.isHexDigit)
    return CodeResult(
      app: app, ref: ref, sha: sha, output: output,
      warnings: (fetch || immutable ? [] : stale(selection)) + warnings)
  }

  /// Resolves `ref` to a commit. A ref git rejects or can't find is `not_found`; when its
  /// `origin/` counterpart resolves, the error suggests repeating the read with that ref.
  private func resolve(
    _ ref: String, app: String, selection: Selection, operation: CodeRead
  ) async throws -> String {
    let peel = { (ref: String) in
      ["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"]
    }
    let resolved = try await run(peel(ref), selection, operation)
    switch resolved.termination {
    case .exit(0): return try decodeSHA(resolved.stdout, selection)
    case .exit(1):
      // A ref can exist even when its commit object is unavailable.
      let unpeeled = try await run(
        ["rev-parse", "--verify", "--quiet", "--end-of-options", ref], selection, operation)
      if unpeeled.termination == .exit(0) {
        let object = try decodeSHA(unpeeled.stdout, selection)
        let exists = try await run(["cat-file", "-e", object + "^{}"], selection, operation)
        guard exists.termination == .exit(0) else { throw failure(selection) }
      } else if unpeeled.termination != .exit(1) {
        throw failure(selection)
      }
    case .exit(128):
      // Git rejects a ref it can't parse, such as `main@{999}`, as it rejects a broken clone.
      let clone = try await run(["rev-parse", "--git-dir"], selection, operation)
      guard clone.termination == .exit(0) else { throw failure(selection) }
    default: throw failure(selection)
    }
    let remote = "origin/" + ref
    let suggestion = try await run(peel(remote), selection, operation)
    throw CodeError.notFound(
      "Commit for Git ref \(ref.debugDescription) not found.",
      next: suggestion.termination == .exit(0)
        ? [operation.command(workspace: workspace, target: app + "@" + remote, prod: false)]
        : [
          "silta --ws \(shellWord(workspace)) repo fetch \(shellWord(selection.repo))",
          "silta --ws \(shellWord(workspace)) ws show",
        ])
  }

  private func content(
    _ operation: CodeRead, sha: String, selection: Selection, target: String
  ) async throws -> (output: String, warnings: [OutputWarning]) {
    try await requirePath(operation, sha: sha, selection: selection, target: target)
    let result = try await run(
      operation.arguments(sha: sha, subpath: selection.subpath), selection, operation)
    if result.termination != .exit(0) {
      switch operation {
      case .grep where result.termination == .exit(1): break
      case .grep where result.stderr.starts(with: Data("fatal: -e option,".utf8)):
        throw CodeError.invalid("Invalid extended regular expression.", command: "silta code grep")
      default: throw failure(selection)
      }
    }
    return try operation.formatted(
      CodeRead.text(result.stdout), sha: sha, subpath: selection.subpath,
      unreadable: failure(selection))
  }

  /// Checks that a shown path is a file and a listed one a directory, naming what was found.
  private func requirePath(
    _ operation: CodeRead, sha: String, selection: Selection, target: String
  ) async throws {
    let path = CodeRead.normalized(selection.subpath + "/" + operation.path)
    let expected: Substring
    switch operation {
    case .show: expected = "blob"
    case .list where !path.isEmpty: expected = "tree"
    default: return
    }
    let found = try await kind(of: path, sha: sha, selection: selection, operation: operation)
    guard found != expected else { return }
    let shown = operation.path.debugDescription
    let other = { (read: CodeRead) in
      read.command(workspace: workspace, target: target, prod: false)
    }
    switch found {
    case "tree":
      throw CodeError.notFound(
        "Path \(shown) is a directory at the selected commit.",
        next: [other(.list(operation.path))])
    case "blob":
      throw CodeError.notFound(
        "Path \(shown) is a file at the selected commit.",
        next: [other(.show(operation.path, lines: nil))])
    default:
      let subpath = CodeRead.normalized(selection.subpath)
      guard !subpath.isEmpty,
        try await kind(of: subpath, sha: sha, selection: selection, operation: operation)
          != "tree"
      else {
        throw CodeError.notFound(
          "Path \(shown) not found at selected commit.", next: [other(.list(nil))])
      }
      throw CodeError.notFound(
        "App subpath \(selection.subpath.debugDescription) not found at selected commit.",
        next: ["silta --ws \(shellWord(workspace)) ws show"])
    }
  }

  /// The object type (`blob`, `tree`, …) at a literal repo path, nil when absent; the
  /// repo root is a tree.
  private func kind(
    of path: String, sha: String, selection: Selection, operation: CodeRead
  ) async throws -> Substring? {
    guard !path.isEmpty else { return "tree" }
    let result = try await run(
      ["--literal-pathspecs", "ls-tree", "-z", sha, "--", path], selection, operation)
    guard result.termination == .exit(0) else { throw failure(selection) }
    return CodeRead.text(result.stdout).split(separator: " ", maxSplits: 2).dropFirst().first
  }

  private func decodeSHA(_ bytes: Data, _ selection: Selection) throws -> String {
    let sha = (String(bytes: bytes, encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
    guard [40, 64].contains(sha.count), sha.allSatisfy({ $0.isHexDigit }) else {
      throw failure(selection)
    }
    return sha
  }

  private func failure(_ selection: Selection) -> CodeError {
    .git(repo: selection.repo, workspace: workspace)
  }

  /// Runs git in the selected clone. `format.pretty` from the user's configuration is
  /// read even beside an explicit `--format`, and an invalid value fails the read, so it
  /// is pinned.
  private func run(
    _ arguments: [String], _ selection: Selection, _ operation: CodeRead
  ) async throws -> GitResult {
    let result: GitResult
    do {
      result = try await git.run(
        .init(
          arguments: ["--no-pager", "-c", "format.pretty=medium"] + arguments,
          directory: URL(filePath: selection.path, directoryHint: .isDirectory)))
    } catch { throw failure(selection) }
    switch result.termination {
    case .exit: return result
    case .timedOut: throw CodeError.timeout(command: "silta code " + operation.verb)
    case .signal: throw failure(selection)
    }
  }

  private func select(_ app: String) throws
    -> Selection
  {
    try store.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT app.ref,app.prod_ref,app.subpath,repo.slug,repo_path.path,repo_path.fetched_at
            FROM app JOIN workspace ON workspace.id=app.workspace_id
            JOIN repo ON repo.id=app.repo_id LEFT JOIN repo_path ON repo_path.repo_id=repo.id
            WHERE workspace.slug=? AND app.slug=?
            """, arguments: [workspace, app])
      else {
        throw CodeError.notFound(
          "App \(app.debugDescription) not found.",
          next: ["silta --ws \(shellWord(workspace)) ws show"])
      }
      let repo: String = row["slug"]
      guard let path: String = row["path"], FileManager.default.fileExists(atPath: path + "/.git")
      else {
        throw RepoError.localPath(repo: repo, workspace: workspace)
      }
      return Selection(
        ref: row["ref"], prod: row["prod_ref"], subpath: row["subpath"] ?? "", repo: repo,
        path: path, fetched: row["fetched_at"])
    }
  }

  private func stale(_ selection: Selection)
    -> [OutputWarning]
  {
    let hint =
      "run silta --ws \(shellWord(workspace)) repo fetch \(shellWord(selection.repo)) (needs network)."
    guard let text = selection.fetched,
      let fetched = try? Date(text, strategy: .iso8601)  // invalid means unknown
    else { return [.init(code: "ref_stale", message: "No fetch recorded; " + hint)] }
    let age = date.timeIntervalSince(fetched)
    guard age >= 86_400 else { return [] }
    return [.init(code: "ref_stale", message: "fetched \(Int(age / 3600)) h ago; " + hint)]
  }
}

private struct Selection {
  let ref: String
  let prod: String?
  let subpath: String
  let repo: String
  let path: String
  let fetched: String?
}
