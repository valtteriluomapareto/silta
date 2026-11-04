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
    guard let app = parts.first, !app.isEmpty,
      parts.count == 1 || (!parts[1].isEmpty && !prod), !target.contains("\0")
    else {
      throw CodeError.invalid(
        "Use app[@ref], or app with --prod.", command: "silta code \(operation.verb)")
    }
    let selection = try select(String(app))
    try operation.validate(subpath: selection.subpath)
    let ref = parts.count == 2 ? String(parts[1]) : (prod ? selection.prod : selection.ref)
    let configuration = "silta --ws \(shellWord(workspace)) ws show"
    guard let ref else {
      throw CodeError.notFound(
        "App \(app.debugDescription) has no prod_ref.", next: [configuration])
    }
    if fetch {
      _ = try await RepositoryFetch.fetch(
        selection.repo, workspace: workspace, store: store, git: git, at: date)
    }
    let sha = try await resolve(ref, selection: selection)
    let path = CodeRead.normalized(selection.subpath + "/" + operation.path)
    let output = try await content(
      operation, sha: sha, path: path, selection: selection, target: String(app) + "@" + ref)
    let warnings = fetch ? [] : stale(selection)
    return CodeResult(app: String(app), ref: ref, sha: sha, output: output, warnings: warnings)
  }

  private func resolve(_ ref: String, selection: Selection) async throws -> String {
    let directory = URL(filePath: selection.path, directoryHint: .isDirectory)
    let failure = CodeError.git(repo: selection.repo, workspace: workspace)
    let resolved = try await run(
      ["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"],
      directory: directory, failure: failure)
    if resolved.termination == .exit(1) {
      // A ref can exist even when its commit object is unavailable.
      let unpeeled = try await run(
        ["rev-parse", "--verify", "--quiet", "--end-of-options", ref],
        directory: directory, failure: failure)
      if unpeeled.termination == .exit(0) {
        let object = try decodeSHA(unpeeled.stdout, failure: failure)
        let exists = try await run(
          ["cat-file", "-e", object + "^{}"], directory: directory, failure: failure)
        guard exists.termination == .exit(0) else { throw failure }
      } else if unpeeled.termination != .exit(1) {
        throw failure
      }
      throw CodeError.notFound(
        "Commit for Git ref \(ref.debugDescription) not found.",
        next: [
          "silta --ws \(shellWord(workspace)) repo fetch \(shellWord(selection.repo))",
          "silta --ws \(shellWord(workspace)) ws show",
        ])
    }
    guard resolved.termination == .exit(0) else { throw failure }
    return try decodeSHA(resolved.stdout, failure: failure)
  }

  private func content(
    _ operation: CodeRead, sha: String, path: String, selection: Selection, target: String
  ) async throws -> String {
    let failure = CodeError.git(repo: selection.repo, workspace: workspace)
    try await requirePath(operation, sha: sha, path: path, selection: selection, target: target)
    let result = try await run(
      operation.arguments(sha: sha, path: path),
      directory: URL(filePath: selection.path, directoryHint: .isDirectory),
      failure: failure)
    if result.termination != .exit(0) {
      switch operation {
      case .grep where result.termination == .exit(1): break
      case .grep where result.stderr.starts(with: Data("fatal: -e option,".utf8)):
        throw CodeError.invalid("Invalid Git basic regular expression.", command: "silta code grep")
      default: throw failure
      }
    }
    guard let output = String(bytes: result.stdout, encoding: .utf8) else { throw failure }
    return try operation.formatted(output, sha: sha, subpath: selection.subpath)
  }

  private func requirePath(
    _ operation: CodeRead, sha: String, path: String,
    selection: Selection, target: String
  ) async throws {
    let type: String
    switch operation {
    case .show: type = "blob"
    case .list where !path.isEmpty: type = "tree"
    default: return
    }
    let failure = CodeError.git(repo: selection.repo, workspace: workspace)
    let result = try await run(
      ["--literal-pathspecs", "ls-tree", "-z", sha, "--", path],
      directory: URL(filePath: selection.path, directoryHint: .isDirectory), failure: failure)
    guard result.termination == .exit(0), let output = String(bytes: result.stdout, encoding: .utf8)
    else { throw failure }
    guard output.split(separator: " ", maxSplits: 2).dropFirst().first == Substring(type) else {
      throw CodeError.notFound(
        "Path \(operation.path.debugDescription) not found at selected commit.",
        next: ["silta --ws \(shellWord(workspace)) code ls \(shellWord(target))"])
    }
  }

  private func decodeSHA(_ bytes: Data, failure: CodeError) throws -> String {
    guard let value = String(bytes: bytes, encoding: .utf8) else { throw failure }
    let sha = value.trimmingCharacters(in: .newlines)
    guard [40, 64].contains(sha.count), sha.allSatisfy({ $0.isHexDigit }) else { throw failure }
    return sha
  }

  private func run(
    _ arguments: [String], directory: URL,
    failure: CodeError
  ) async throws -> GitResult {
    let result: GitResult
    do {
      result = try await git.run(
        .init(
          arguments: ["--no-pager", "-c", "format.pretty=medium"] + arguments, directory: directory)
      )
    } catch { throw failure }
    switch result.termination {
    case .exit: return result
    default: throw failure
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
