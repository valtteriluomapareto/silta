import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SessionTests {
  private let cwd = URL(filePath: "/Acme/worktree/nested")
  private let terminal = TerminalState(stdin: false, stdout: false)

  @Test func explicitSessionNeverCallsGit() async throws {
    let session = "acme"
    let git = ScriptedGitRunner(script: [])
    let (actor, _) = try await ActorID.resolve(
      environment: ["SILTA_SESSION": session], terminal: terminal, git: git, directory: cwd)
    #expect(actor.description == "agent:unknown:\(session)")
    #expect(git.requests.isEmpty)
  }

  @Test func acceptedExplicitActorNeverNeedsASessionOrGit() async throws {
    let git = ScriptedGitRunner(script: [])
    let (actor, _) = try await ActorID.resolve(
      environment: ["SILTA_ACTOR": "agent:acme:explicit"], terminal: terminal, git: git,
      directory: cwd)
    #expect(actor.description == "agent:acme:explicit")
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
    let (actor, _) = try await ActorID.resolve(
      environment: [:], terminal: terminal, git: git, directory: cwd)
    #expect(actor.description == "agent:unknown:\(expected)")
    #expect(git.requests == [request])
  }

  @Test func carriageReturnAtTheEndOfRootIsPreserved() async throws {
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: cwd)
    let result = GitResult(termination: .exit(0), stdout: Data("/Acme/path\r\n".utf8))
    let git = ScriptedGitRunner(script: [(request, .success(result))])
    let (actor, _) = try await ActorID.resolve(
      environment: [:], terminal: terminal, git: git, directory: cwd)
    #expect(actor.description == "agent:unknown:082628")
  }

  @Test func outsideRepositoryHashesTheCwd() async throws {
    let directory = URL(filePath: "/Acme/worktree")
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
    let git = ScriptedGitRunner(script: [(request, .success(GitResult(termination: .exit(128))))])
    let (actor, _) = try await ActorID.resolve(
      environment: [:], terminal: terminal, git: git, directory: directory)
    #expect(actor.description == "agent:unknown:8e7b6a")
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
  func gitFaultsFallBackToTheCwd(outcome: Result<GitResult, SeamError>) async throws {
    let directory = URL(filePath: "/Acme/worktree")
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
    let git = ScriptedGitRunner(script: [(request, outcome.mapError { $0 as any Error })])
    let (actor, _) = try await ActorID.resolve(
      environment: [:], terminal: terminal, git: git, directory: directory)
    #expect(actor.description == "agent:unknown:8e7b6a")
  }

  // A fallback inside a repository splits one session in two, so it leaves a trace.
  @Test func gitFaultWarnsButLeavingARepositoryDoesNot() async throws {
    let directory = URL(filePath: "/Acme/worktree")
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
    let outside = Data("fatal: not a git repository (or any of the parent directories): .git".utf8)
    let corrupt = Data("fatal: Expected git repo version <= 1, found 99".utf8)
    for (termination, stderr, warned) in [
      (GitTermination.timedOut, Data(), true), (.exit(128), outside, false),
      (.exit(128), corrupt, true),
    ] {
      let git = ScriptedGitRunner(script: [
        (request, .success(GitResult(termination: termination, stderr: stderr)))
      ])
      let (_, warnings) = try await ActorID.resolve(
        environment: [:], terminal: terminal, git: git, directory: directory)
      #expect(warnings.map(\.code) == (warned ? ["session_fallback"] : []))
    }
  }

  @Test func emptySessionCountsAsUnsetAndAMalformedOneIsRefused() async throws {
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: cwd)
    let git = ScriptedGitRunner(script: [
      (request, .success(GitResult(termination: .exit(0), stdout: Data("/Acme/worktree\n".utf8))))
    ])
    let (actor, _) = try await ActorID.resolve(
      environment: ["SILTA_SESSION": ""], terminal: terminal, git: git, directory: cwd)
    #expect(actor.description == "agent:unknown:8e7b6a")
    await #expect(throws: SeamError.invalidSession) {
      try await ActorID.resolve(
        environment: ["SILTA_SESSION": "acme session"], terminal: terminal,
        git: ScriptedGitRunner(script: []), directory: cwd)
    }
  }

  @Test func explicitAgentWithoutSessionGetsTheResolvedOne() async throws {
    let (actor, _) = try await ActorID.resolve(
      environment: ["SILTA_ACTOR": "agent:acme", "SILTA_SESSION": "review"], terminal: terminal,
      git: ScriptedGitRunner(script: []), directory: cwd)
    #expect(actor.description == "agent:acme:review")
  }

  // Only a human watching stdout hears about a dropped override; an agent whose shell
  // inherited the human's export would see it on every call.
  @Test(arguments: [(true, ["actor_override_ignored"]), (false, [])])
  func ignoredHumanOverrideWarnsOnlyAWatchingHuman(stdout: Bool, expected: [String]) async throws {
    let (actor, warnings) = try await ActorID.resolve(
      environment: ["SILTA_ACTOR": "human:acme", "SILTA_SESSION": "acme"],
      terminal: TerminalState(stdin: false, stdout: stdout),
      git: ScriptedGitRunner(script: []), directory: cwd)
    #expect(actor.description == "agent:unknown:acme")
    #expect(warnings.map(\.code) == expected)
  }
}
