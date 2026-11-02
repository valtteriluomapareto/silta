import Darwin
import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GitRunnerTests {
  @Test(arguments: [false, true]) func gitContract(scripted: Bool) async throws {
    try await withScratchDirectory { scratch in
      let request = GitRequest(
        arguments: ["rev-parse", "--is-inside-work-tree"], directory: scratch)
      let system = try SystemGitRunner()
      let expected = try await system.run(request)
      #expect(expected.termination == .exit(128))
      #expect(expected.stdout.isEmpty)
      #expect(!expected.stderr.isEmpty)
      let fake = ScriptedGitRunner(steps: [(request, expected)])
      let runner: any GitRunner = scripted ? fake : system
      #expect(try await runner.run(request) == expected)
      if scripted {
        #expect(fake.requests == [request])
        #expect(fake.isExhausted)
        await #expect(throws: (any Error).self) { try await runner.run(request) }
      }
    }
  }

  @Test func gitFixtureHasSeparateStreamsAndNoWorkingTreeWrites() async throws {
    try await withScratchDirectory { scratch in
      let runner = try SystemGitRunner()
      let initialized = try await runner.run(
        GitRequest(arguments: ["init", "-q"], directory: scratch))
      #expect(initialized.termination == .exit(0))
      let result = try await runner.run(
        GitRequest(arguments: ["rev-parse", "--is-inside-work-tree"], directory: scratch))
      #expect(result.stdout == Data("true\n".utf8))
      #expect(result.stderr.isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == [".git"])
    }
  }

  @Test func environmentIsIsolatedAndOutputCannotFillAPipe() async throws {
    try await withScratchDirectory { scratch in
      let script = scratch.appending(path: "git")
      let source =
        "#!/bin/sh\n/usr/bin/env\nprintf err >&2\n"
        + "/usr/bin/awk 'BEGIN { for(i=0;i<20000;i++) print \"data\" }'\n"
      try Data(source.utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let result = try await SystemGitRunner(executable: script.path).run(
        GitRequest(arguments: [], directory: scratch))
      #expect(result.termination == .exit(0))
      let text = try #require(String(data: result.stdout, encoding: .utf8))
      #expect(text.contains("GIT_TERMINAL_PROMPT=0\n"))
      #expect(text.contains("GIT_OPTIONAL_LOCKS=0\n"))
      #expect(text.contains("LC_ALL=C\n"))
      #expect(!text.contains("SILTA_"))
      #expect(text.contains("GIT_CONFIG_NOSYSTEM=1\n"))
      #expect(text.contains("GIT_CONFIG_GLOBAL=/dev/null\n"))
      #expect(!text.contains("GIT_CONFIG_COUNT="))
      #expect(text.components(separatedBy: "data\n").count == 20001)
      #expect(result.stderr == Data("err".utf8))
    }
  }

  @Test func timeoutKillsAChildIgnoringTermination() async throws {
    try await withScratchDirectory { scratch in
      let script = scratch.appending(path: "git")
      // The handler must be installed within the deadline; the captured marker verifies
      // readiness in successful runs. Process startup under heavy load can exceed it.
      try Data("#!/bin/sh\ntrap '' TERM\nprintf ready\nwhile :; do :; done\n".utf8).write(
        to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let result = try await SystemGitRunner(executable: script.path, killAfter: 0).run(
        GitRequest(arguments: [], directory: scratch, timeout: 1))
      #expect(result.termination == .timedOut)
      #expect(result.stdout == Data("ready".utf8))
    }
  }

  @Test func validatesExecutableDeadlineAndScriptOrder() async throws {
    try await withScratchDirectory { scratch in
      #expect(GitRequest(arguments: ["fetch"], directory: scratch).timeout == 60)
      #expect(GitRequest(arguments: ["status"], directory: scratch).timeout == 10)
      #expect(throws: (any Error).self) { try SystemGitRunner(executable: "git") }
      let runner = try SystemGitRunner(executable: scratch.appending(path: "absent").path)
      let request = GitRequest(arguments: [], directory: scratch)
      await #expect(throws: (any Error).self) { try await runner.run(request) }
      let fake = ScriptedGitRunner(steps: [(request, GitResult(termination: .exit(0)))])
      await #expect(throws: (any Error).self) {
        try await fake.run(GitRequest(arguments: ["wrong"], directory: scratch))
      }
      #expect(!fake.isExhausted)
      for timeout in [0.0, -1, .nan, .infinity] {
        await #expect(throws: (any Error).self) {
          try await SystemGitRunner().run(
            GitRequest(arguments: [], directory: scratch, timeout: timeout))
        }
      }
    }
  }
  @Test(arguments: [false, true]) func preservesBinaryStreamsAndSignals(scripted: Bool) async throws
  {
    try await withScratchDirectory { scratch in
      let script = scratch.appending(path: "git")
      try Data("#!/bin/sh\nprintf '\\377\\000'\nprintf '\\376' >&2\nkill -ABRT $$\n".utf8).write(
        to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let request = GitRequest(arguments: [], directory: scratch)
      let expected = GitResult(
        termination: .signal(SIGABRT), stdout: Data([255, 0]), stderr: Data([254]))
      let runner: any GitRunner =
        scripted
        ? ScriptedGitRunner(steps: [(request, expected)])
        : try SystemGitRunner(executable: script.path)
      #expect(try await runner.run(request) == expected)
    }
  }

  private enum Planted: Error { case spawn }

  @Test func scriptCanReplayThrownFaults() async throws {
    try await withScratchDirectory { scratch in
      let request = GitRequest(arguments: ["fetch"], directory: scratch)
      let fake = ScriptedGitRunner(script: [(request, .failure(Planted.spawn))])
      await #expect(throws: Planted.self) { try await fake.run(request) }
      #expect(fake.isExhausted)
      #expect(fake.requests == [request])
    }
  }

  @Test func descendantOutputDescriptorsDoNotDelayReturn() async throws {
    try await withScratchDirectory { scratch in
      let fifo = scratch.appending(path: "hold")
      try #require(mkfifo(fifo.path, 0o600) == 0)
      let script = scratch.appending(path: "git")
      try Data("#!/bin/sh\n/bin/cat \"$1\" &\nprintf '%s' \"$!\"\n".utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let result = try await SystemGitRunner(executable: script.path).run(
        GitRequest(arguments: [fifo.path], directory: scratch))
      let text = try #require(String(data: result.stdout, encoding: .utf8))
      let descendant = try #require(Int32(text))
      defer { kill(descendant, SIGKILL) }
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
    }
  }

}
