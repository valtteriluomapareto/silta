import Foundation

/// Git values captured before a task transaction begins.
struct TaskGit: Sendable {
  var branch: String?

  var worktree: String?

  var sha: String?

  var dirty: Bool?

  static func inspect(
    repo: String?, directory: URL, runner: any GitRunner,
    enabled: Bool, completion: Bool, sha: String? = nil
  ) async throws -> TaskGit {
    guard enabled else { return TaskGit() }
    guard let repo, FileManager.default.fileExists(atPath: repo + "/.git") else {
      throw TaskError.repository
    }
    let registered = URL(filePath: repo, directoryHint: .isDirectory)
    let identityArgs = ["rev-parse", "--path-format=absolute", "--git-common-dir"]
    let expected = try await value(identityArgs, directory: registered, runner: runner)
    let actual = try await value(identityArgs, directory: directory, runner: runner)
    guard
      URL(filePath: actual).resolvingSymlinksInPath().path
        == URL(filePath: expected).resolvingSymlinksInPath().path
    else { throw TaskError.foreignRepo }
    let root = try await value(
      ["rev-parse", "--show-toplevel"], directory: directory, runner: runner)
    let branch = try await value(
      ["rev-parse", "--abbrev-ref", "HEAD"], directory: directory, runner: runner)
    guard completion else { return TaskGit(branch: branch, worktree: root) }
    let commit = try await commitValue(sha, directory: directory, runner: runner)
    guard commit.wholeMatch(of: /[a-f0-9]{40}|[a-f0-9]{64}/) != nil else { throw TaskError.git }
    let status = try await value(["status", "--porcelain"], directory: directory, runner: runner)
    return TaskGit(branch: branch, worktree: root, sha: commit, dirty: !status.isEmpty)
  }

  private static func commitValue(
    _ sha: String?, directory: URL, runner: any GitRunner
  ) async throws -> String {
    let result: GitResult
    do {
      result = try await runner.run(
        .init(
          arguments: [
            "rev-parse", "--verify", "--quiet", "--end-of-options", (sha ?? "HEAD") + "^{commit}",
          ], directory: directory))
    } catch {
      throw TaskError.git
    }
    if result.termination == .exit(1), sha != nil { throw TaskError.foreignRepo }
    guard result.termination == .exit(0),
      let text = String(data: result.stdout, encoding: .utf8)
    else { throw TaskError.git }
    return text.trimmingCharacters(in: .newlines)
  }

  private static func value(
    _ arguments: [String], directory: URL, runner: any GitRunner
  ) async throws -> String {
    do {
      let result = try await runner.run(.init(arguments: arguments, directory: directory))
      guard result.termination == .exit(0), let text = String(data: result.stdout, encoding: .utf8)
      else { throw TaskError.git }
      return text.trimmingCharacters(in: .newlines)
    } catch {
      throw TaskError.git
    }
  }
}
