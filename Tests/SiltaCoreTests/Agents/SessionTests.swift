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
    let actor = try await Actor.resolve(
      environment: ["SILTA_SESSION": session], terminal: terminal, git: git, directory: cwd)
    #expect(actor.value == "agent:unknown:\(session)")
    #expect(git.requests.isEmpty)
  }

  @Test func acceptedExplicitActorNeverNeedsASessionOrGit() async throws {
    let git = ScriptedGitRunner(script: [])
    let actor = try await Actor.resolve(
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
    let actor = try await Actor.resolve(
      environment: [:], terminal: terminal, git: git, directory: cwd)
    #expect(actor.value == "agent:unknown:\(expected)")
    #expect(git.requests == [request])
  }

  @Test func outsideRepositoryHashesTheCwd() async throws {
    let directory = URL(filePath: "/Acme/worktree")
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
    let git = ScriptedGitRunner(script: [(request, .success(GitResult(termination: .exit(128))))])
    let actor = try await Actor.resolve(
      environment: [:], terminal: terminal, git: git, directory: directory)
    #expect(actor.value == "agent:unknown:8e7b6a")
  }

  @Test(arguments: [GitTermination.timedOut, .signal(9)])
  func nonExitGitFaultsAreCoded(termination: GitTermination) async throws {
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: cwd)
    let git = ScriptedGitRunner(script: [(request, .success(GitResult(termination: termination)))])
    await #expect(throws: SeamError.gitCapture) {
      try await Actor.resolve(environment: [:], terminal: terminal, git: git, directory: cwd)
    }
  }

  @Test(arguments: [Data(), Data("relative\n".utf8), Data([0xff])])
  func malformedSuccessIsCoded(bytes: Data) async throws {
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: cwd)
    let git = ScriptedGitRunner(script: [
      (request, .success(GitResult(termination: .exit(0), stdout: bytes)))
    ])
    await #expect(throws: SeamError.gitCapture) {
      try await Actor.resolve(environment: [:], terminal: terminal, git: git, directory: cwd)
    }
  }

  @Test func spawnFailurePreservesItsCode() async throws {
    let request = GitRequest(arguments: ["rev-parse", "--show-toplevel"], directory: cwd)
    let git = ScriptedGitRunner(script: [(request, .failure(SeamError.gitUnavailable))])
    await #expect(throws: SeamError.gitUnavailable) {
      try await Actor.resolve(environment: [:], terminal: terminal, git: git, directory: cwd)
    }
  }
}
