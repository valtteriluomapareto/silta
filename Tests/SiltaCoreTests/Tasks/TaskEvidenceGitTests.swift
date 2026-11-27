import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct TaskEvidenceGitTests {
  private let sha = String(repeating: "a", count: 40)
  private let tip = String(repeating: "b", count: 40)
  private let ref = "refs/remotes/origin/main"

  @Test(arguments: [false, true])
  func negativeAncestryRequiresCompleteHistory(shallow: Bool) async throws {
    try await withScratchDirectory { scratch in
      let repo = try self.repo(scratch)
      let runner = scripted(
        [
          (query("refs/heads/origin/main"), result(0)),
          (symbolic("refs/heads/origin/main"), result(1)),
          (query(ref), result(0, "\(ref) \(tip)\n")),
          (resolve(tip), result(0, tip + "\n")),
          (resolve(sha), result(0, sha + "\n")),
          (["merge-base", "--is-ancestor", sha, tip], result(1)),
          (["rev-parse", "--is-shallow-repository"], result(0, shallow ? "true\n" : "false\n")),
        ], at: scratch)
      var evidence = TaskEvidenceGit(runner: runner)
      let first = await evidence.tip("origin/main", repo: repo)
      let exact = await evidence.tip(ref, repo: repo)
      let state = await evidence.reachability(sha, at: exact, repo: repo)
      let same = await evidence.reachability(sha, at: exact, repo: repo)
      #expect(first == exact)
      #expect(exact == .found(ref: ref, sha: tip))
      #expect(state == (shallow ? .unknown : .unreachable) && same == state)
      #expect(runner.isExhausted)
      #expect(runner.requests.count == 7)
      #expect(
        runner.requests.allSatisfy { !$0.lazyFetch && $0.timeout <= 0.5 && $0.capture != nil })
    }
  }

  @Test func ambiguousShortRefAndTimedOutProbeStayUnknown() async throws {
    try await withScratchDirectory { scratch in
      let repo = try self.repo(scratch)
      let local = "refs/heads/origin/main"
      let runner = scripted(
        [
          (query(local), result(0, "\(local) \(sha)\n")),
          (resolve(sha), result(0, sha + "\n")),
          (query(ref), result(0, "\(ref) \(tip)\n")),
          (resolve(tip), result(0, tip + "\n")),
          (query("refs/heads/slow"), GitResult(termination: .timedOut)),
        ], at: scratch)
      var evidence = TaskEvidenceGit(runner: runner)
      #expect(await evidence.tip("origin/main", repo: repo) == .unknown)
      #expect(await evidence.tip(ref, repo: repo) == .found(ref: ref, sha: tip))
      #expect(await evidence.tip("slow", repo: repo, localOnly: true) == .unknown)
      #expect(runner.isExhausted)
    }
  }

  @Test func requiresTheRequestedOIDAndDistinguishesUnresolvedFromMissing() async throws {
    try await withScratchDirectory { scratch in
      let repo = try self.repo(scratch)
      let absent = "refs/heads/absent"
      let broken = "refs/heads/broken"
      let dangling = "refs/heads/dangling"
      let tip64 = tip + String(repeating: "c", count: 24)
      let runner = scripted(
        [
          (query(ref), result(0, "\(ref) \(tip64)\n")),
          (resolve(tip64), result(0, tip64 + "\n")),
          (resolve(sha), result(0, sha + String(repeating: "f", count: 24) + "\n")),
          (query(absent), result(0, "\(absent)/nested \(tip64)\n")),
          (symbolic(absent), result(1)),
          (query(broken), result(0, "\(broken) \(tip64)\n")),
          (resolve(tip64), result(1)),
          (query(dangling), result(0)),
          (symbolic(dangling), result(0, "refs/heads/gone\n")),
        ], at: scratch)
      var evidence = TaskEvidenceGit(runner: runner)
      let tip = await evidence.tip(ref, repo: repo)
      #expect(await evidence.reachability(sha, at: tip, repo: repo) == .unknown)
      #expect(await evidence.tip("absent", repo: repo, localOnly: true) == .missing)
      #expect(await evidence.tip("broken", repo: repo, localOnly: true) == .unknown)
      #expect(await evidence.tip("dangling", repo: repo, localOnly: true) == .unknown)
      #expect(runner.isExhausted && runner.requests.count == 9)
    }
  }

  @Test func configuredAnnotatedTagUsesItsCapturedCommit() async throws {
    try await withScratchDirectory { scratch in
      let tag = "refs/tags/v1"
      let repo = try self.repo(scratch, appRef: tag)
      let runner = scripted(
        [(query(tag), result(0, "\(tag) \(sha)\n")), (resolve(sha), result(0, tip + "\n"))],
        at: scratch)
      var evidence = TaskEvidenceGit(runner: runner)
      #expect(await evidence.configuredTip(repo) == .found(ref: tag, sha: tip))
      #expect(runner.isExhausted)
    }
  }

  private func repo(_ scratch: URL, appRef: String? = nil) throws -> TaskEvidenceRepo {
    try FileManager.default.createDirectory(
      at: scratch.appending(path: ".git"), withIntermediateDirectories: false)
    return TaskEvidenceRepo(
      id: 1, name: "platform", path: scratch.path, appRef: appRef ?? ref, fetchedAt: nil)
  }

  private func query(_ ref: String) -> [String] {
    ["for-each-ref", "--count=2", "--format=%(refname) %(objectname)", "--", ref]
  }

  private func symbolic(_ ref: String) -> [String] {
    ["symbolic-ref", "--quiet", "--no-recurse", ref]
  }

  private func resolve(_ object: String) -> [String] {
    ["rev-parse", "--verify", "--quiet", "--end-of-options", object + "^{commit}"]
  }

  private func result(_ exit: Int32, _ text: String = "") -> GitResult {
    GitResult(termination: .exit(exit), stdout: Data(text.utf8))
  }

  private func scripted(_ steps: [([String], GitResult)], at location: URL) -> ScriptedGitRunner {
    ScriptedGitRunner(
      script: steps.map { arguments, response in
        (
          GitRequest(
            arguments: ["--no-pager", "--no-replace-objects"] + arguments,
            directory: URL(filePath: location.path, directoryHint: .isDirectory), timeout: 0.5,
            lazyFetch: false, capture: .init(byteLimit: 1024)),
          .success(response)
        )
      })
  }
}
