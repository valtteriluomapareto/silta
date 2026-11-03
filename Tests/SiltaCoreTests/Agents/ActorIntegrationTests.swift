import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(3)), .tags(.slow), .enabled(if: slowTestsEnabled()))
struct ActorIntegrationTests {
  @Test func nestedCwdSharesSessionButDistinctWorktreeDoesNot() async throws {
    try await withScratchDirectory { scratch in
      let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let fixtures = scratch.appending(path: "fixtures")
      let setup = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"),
        [root.appending(path: "scripts/make-fixtures.sh").path, fixtures.path], in: scratch)
      try #require(setup.termination == .exit(0), "\(setup.stderr)")
      let terminal = TerminalState(stdin: false, stdout: false)
      let git = SystemGitRunner(environment: [
        "HOME": scratch.path, "XDG_CONFIG_HOME": scratch.appending(path: "config").path,
        "PATH": "/usr/bin:/bin",
      ])
      let repo = fixtures.appending(path: "acme-platform")
      let first = await Actor.resolve(
        environment: [:], terminal: terminal, git: git, directory: repo)
      let nested = await Actor.resolve(
        environment: [:], terminal: terminal, git: git, directory: repo.appending(path: "api"))
      let worktree = await Actor.resolve(
        environment: [:], terminal: terminal, git: git,
        directory: fixtures.appending(path: "acme-portal-worktree"))
      let mainWorktree = await Actor.resolve(
        environment: [:], terminal: terminal, git: git,
        directory: fixtures.appending(path: "acme-platform"))
      let outside = await Actor.resolve(
        environment: [:], terminal: terminal, git: git, directory: scratch)
      #expect(outside.value.hasPrefix("agent:unknown:"))
      #expect(outside.value.count == "agent:unknown:".count + 6)
      #expect(mainWorktree != worktree)
      #expect(first == nested)
      #expect(first != worktree)
      #expect(first.value.hasPrefix("agent:unknown:"))
    }
  }
}
