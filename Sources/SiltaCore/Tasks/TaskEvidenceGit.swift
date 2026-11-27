import Foundation

/// The registered clone and the exact app ref captured in the task read snapshot.
struct TaskEvidenceRepo: Sendable {
  let id: Int64
  let name: String
  let path: String?
  let appRef: String
  let fetchedAt: String?
}

/// A single bounded, local-only Git read for one task.
struct TaskEvidenceGit {
  enum Tip: Equatable {
    case found(ref: String, sha: String)
    case missing
    case unknown
  }

  private struct Key: Hashable {
    let repo: Int64
    let value: String
  }

  private let runner: any GitRunner
  private let deadline = ContinuousClock.now + .seconds(3)
  private var remaining = 30
  private var tips: [Key: Tip] = [:]
  private var commits: [Key: Bool] = [:]
  private var complete: [Int64: Bool] = [:]
  private var ancestors: [Key: TaskWorkEvidence.Reachability] = [:]

  init(runner: any GitRunner) { self.runner = runner }

  static func isLiteralBranch(_ name: String) -> Bool {
    guard name.utf8.count <= 200, name != "HEAD", !name.contains(".."),
      name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.\/-]*/) != nil,
      RestoreService.canNameInRecovery(name)
    else { return false }
    return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".") && !$0.hasSuffix(".lock")
    }
  }

  mutating func tip(_ name: String, repo: TaskEvidenceRepo?, localOnly: Bool = false) async -> Tip {
    guard let repo, Self.isLiteralBranch(name) else { return .unknown }
    if localOnly { return await exactTip("refs/heads/" + name, repo: repo) }
    if name.hasPrefix("refs/heads/") || name.hasPrefix("refs/remotes/") {
      return await exactTip(name, repo: repo)
    }
    guard !name.hasPrefix("refs/") else { return .unknown }
    let local = await exactTip("refs/heads/" + name, repo: repo)
    guard name.contains("/") else { return local }
    let tracking = await exactTip("refs/remotes/" + name, repo: repo)
    if local == .missing { return tracking }
    if tracking == .missing { return local }
    return .unknown
  }

  mutating func reachability(_ sha: String, at tip: Tip, repo: TaskEvidenceRepo?)
    async -> TaskWorkEvidence.Reachability
  {
    guard let repo, case .found(_, let tipSHA) = tip, await hasCommit(sha, repo: repo)
    else { return .unknown }
    if sha == tipSHA { return .reachable }
    let key = Key(repo: repo.id, value: sha + ":" + tipSHA)
    if let cached = ancestors[key] { return cached }
    let result = await run(["merge-base", "--is-ancestor", sha, tipSHA], repo: repo)
    let state: TaskWorkEvidence.Reachability
    switch result?.termination {
    case .exit(0): state = .reachable
    case .exit(1): state = await completeHistory(repo) ? .unreachable : .unknown
    default: state = .unknown
    }
    ancestors[key] = state
    return state
  }

  private mutating func exactTip(_ ref: String, repo: TaskEvidenceRepo) async -> Tip {
    let key = Key(repo: repo.id, value: ref)
    if let cached = tips[key] { return cached }
    let result = await run(["show-ref", "--exists", ref], repo: repo)
    let tip: Tip
    if result?.termination == .exit(2) {
      tip = .missing
    } else if result?.termination == .exit(0), let sha = await commitID(ref, repo: repo) {
      tip = .found(ref: ref, sha: sha)
      commits[Key(repo: repo.id, value: sha)] = true
    } else {
      tip = .unknown
    }
    tips[key] = tip
    return tip
  }

  private mutating func hasCommit(_ sha: String, repo: TaskEvidenceRepo) async -> Bool {
    let key = Key(repo: repo.id, value: sha)
    if let cached = commits[key] { return cached }
    let found = await commitID(sha, repo: repo) == sha
    commits[key] = found
    return found
  }

  private mutating func commitID(_ ref: String, repo: TaskEvidenceRepo) async -> String? {
    guard
      let result = await run(
        ["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"], repo: repo),
      result.termination == .exit(0), !result.stdoutTruncated,
      let text = String(bytes: result.stdout, encoding: .utf8)
    else { return nil }
    let sha = text.trimmingCharacters(in: .newlines)
    return TaskCommitReference.isFullSHA(sha) ? sha.lowercased() : nil
  }

  private mutating func completeHistory(_ repo: TaskEvidenceRepo) async -> Bool {
    if let cached = complete[repo.id] { return cached }
    let result = await run(["rev-parse", "--is-shallow-repository"], repo: repo)
    let full = result?.termination == .exit(0) && result?.stdout == Data("false\n".utf8)
    complete[repo.id] = full
    return full
  }

  private mutating func run(_ arguments: [String], repo: TaskEvidenceRepo) async -> GitResult? {
    guard remaining > 0, let path = repo.path,
      FileManager.default.fileExists(atPath: path + "/.git")
    else { return nil }
    let left = ContinuousClock.now.duration(to: deadline).components
    let seconds = Double(left.seconds) + Double(left.attoseconds) / 1e18
    guard seconds > 0 else { return nil }
    remaining -= 1
    return try? await runner.run(  // Optional evidence stays unknown on an unavailable Git.
      .init(
        arguments: ["--no-pager", "--no-replace-objects"] + arguments,
        directory: URL(filePath: path, directoryHint: .isDirectory),
        timeout: min(0.5, seconds), lazyFetch: false, capture: .init(byteLimit: 1024)))
  }
}
