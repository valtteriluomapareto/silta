import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SessionTests {
  private let cwd = URL(filePath: "/Acme/worktree/nested")
  private let terminal = TerminalState(stdin: false, stdout: false)

  @Test(arguments: ["acme", ""]) func explicitSessionNeverCallsGit(session: String) async throws {
    let git = ScriptedGitRunner(script: [])
    let actor = await Actor.resolve(
      environment: ["SILTA_SESSION": session], terminal: terminal, git: git, directory: cwd)
    #expect(actor.value == "agent:unknown:\(session)")
    #expect(git.requests.isEmpty)
  }

  @Test func acceptedExplicitActorNeverNeedsASessionOrGit() async throws {
    let git = ScriptedGitRunner(script: [])
    let actor = await Actor.resolve(
      environment: ["SILTA_ACTOR": "agent:acme:explicit"], terminal: terminal, git: git,
      directory: cwd)
    #expect(actor.value == "agent:acme:explicit")
    #expect(git.requests.isEmpty)
  }

  @Test(arguments: [
    ("/Acme/worktree", "8e7b6a"), ("/Acme/other", "bbf159"),
    ("/Acme/space Ω ", "203fea"), ("/Acme/path\n", "961053"),
  ])
  func independentHashVectorsPreservePathContents(root: String, expected: String) async throws {
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: cwd)
    let result = GitResult(termination: .exit(0), stdout: Data((root + "\n").utf8))
    let git = ScriptedGitRunner(script: [(request, .success(result))])
    let actor = await Actor.resolve(
      environment: [:], terminal: terminal, git: git, directory: cwd)
    #expect(actor.value == "agent:unknown:\(expected)")
    #expect(git.requests == [request])
  }

  @Test func carriageReturnAtTheEndOfRootIsPreserved() async throws {
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: cwd)
    let result = GitResult(termination: .exit(0), stdout: Data("/Acme/path\r\n".utf8))
    let git = ScriptedGitRunner(script: [(request, .success(result))])
    let actor = await Actor.resolve(
      environment: [:], terminal: terminal, git: git, directory: cwd)
    #expect(actor.value == "agent:unknown:082628")
  }

  @Test func outsideRepositoryHashesTheCwd() async throws {
    let directory = URL(filePath: "/Acme/worktree")
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
    let git = ScriptedGitRunner(script: [(request, .success(GitResult(termination: .exit(128))))])
    let actor = await Actor.resolve(
      environment: [:], terminal: terminal, git: git, directory: directory)
    #expect(actor.value == "agent:unknown:8e7b6a")
  }

  // Sessions guard against accidents, not attackers (§11): a git fault must not fail the command.
  @Test(arguments: [
    Result<GitResult, SeamError>.success(GitResult(termination: .timedOut)),
    .success(GitResult(termination: .signal(9))),
    .success(GitResult(termination: .exit(0))),
    .success(GitResult(termination: .exit(0), stdout: Data("relative\n".utf8))),
    .success(GitResult(termination: .exit(0), stdout: Data([0xff]))),
    .failure(.gitUnavailable),
  ])
  func gitFaultsFallBackToTheCwd(outcome: Result<GitResult, SeamError>) async {
    let directory = URL(filePath: "/Acme/worktree")
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
    let git = ScriptedGitRunner(script: [(request, outcome.mapError { $0 as any Error })])
    let actor = await Actor.resolve(
      environment: [:], terminal: terminal, git: git, directory: directory)
    #expect(actor.value == "agent:unknown:8e7b6a")
  }
}
