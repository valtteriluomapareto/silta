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
          (["show-ref", "--exists", "refs/heads/origin/main"], result(2)),
          (["show-ref", "--exists", ref], result(0)),
          (resolve(ref), result(0, tip + "\n")),
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
      #expect(runner.requests.count == 6)
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
          (["show-ref", "--exists", local], result(0)),
          (resolve(local), result(0, sha + "\n")),
          (["show-ref", "--exists", ref], result(0)),
          (resolve(ref), result(0, tip + "\n")),
          (["show-ref", "--exists", "refs/heads/slow"], GitResult(termination: .timedOut)),
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
      let runner = scripted(
        [
          (["show-ref", "--exists", ref], result(0)),
          (resolve(ref), result(0, tip + String(repeating: "c", count: 24) + "\n")),
          (resolve(sha), result(0, sha + String(repeating: "f", count: 24) + "\n")),
          (["show-ref", "--exists", absent], result(2)),
          (["show-ref", "--exists", broken], result(0)),
          (resolve(broken), result(1)),
        ], at: scratch)
      var evidence = TaskEvidenceGit(runner: runner)
      let tip = await evidence.tip(ref, repo: repo)
      #expect(await evidence.reachability(sha, at: tip, repo: repo) == .unknown)
      #expect(await evidence.tip("absent", repo: repo, localOnly: true) == .missing)
      #expect(await evidence.tip("broken", repo: repo, localOnly: true) == .unknown)
      #expect(runner.isExhausted && runner.requests.count == 6)
    }
  }

  private func repo(_ scratch: URL) throws -> TaskEvidenceRepo {
    try FileManager.default.createDirectory(
      at: scratch.appending(path: ".git"), withIntermediateDirectories: false)
    return TaskEvidenceRepo(
      id: 1, name: "platform", path: scratch.path, appRef: ref, fetchedAt: nil)
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
