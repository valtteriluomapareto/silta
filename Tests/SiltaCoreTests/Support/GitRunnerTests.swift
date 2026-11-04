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
      let system = SystemGitRunner()
      if !scripted {
        let initialized = try await system.run(
          GitRequest(arguments: ["init", "-q"], directory: scratch))
        #expect(initialized.termination == .exit(0))
      }
      let expected = GitResult(termination: .exit(0), stdout: Data("true\n".utf8))
      let fake = ScriptedGitRunner(script: [(request, .success(expected))])
      let runner: any GitRunner = scripted ? fake : system
      #expect(try await runner.run(request) == expected)
      if scripted {
        #expect(fake.requests == [request])
        #expect(fake.isExhausted)
        await #expect(throws: (any Error).self) { try await runner.run(request) }
      } else {
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == [".git"])
      }
    }
  }

  @Test func nonzeroExitKeepsItsErrorStream() async throws {
    try await withScratchDirectory { scratch in
      let result = try await SystemGitRunner().run(
        GitRequest(arguments: ["rev-parse", "--is-inside-work-tree"], directory: scratch))
      #expect(result.termination == .exit(128))
      #expect(result.stdout.isEmpty)
      #expect(!result.stderr.isEmpty)
    }
  }

  @Test func childEnvironmentIsExactAndPreservesCredentials() async throws {
    try await withScratchDirectory { scratch in
      let inherited = [
        "HOME": scratch.appending(path: "acme-home").path,
        "PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": scratch.appending(path: "acme-agent.sock").path,
        "SILTA_HOME": "isolated", "UNRELATED": "preserved",
        "HTTPS_PROXY": "http://proxy.acme.example", "NO_PROXY": "localhost",
        "XDG_CONFIG_HOME": scratch.appending(path: "config").path, "TMPDIR": scratch.path,
        "GIT_DIR": "ignored", "GIT_SSH_COMMAND": "ignored", "GIT_NO_LAZY_FETCH": "0",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_COUNT": "1", "GIT_TERMINAL_PROMPT": "1",
        "LC_ALL": "fi_FI.UTF-8",
      ]
      let result = try await SystemGitRunner(executable: "/usr/bin/env", environment: inherited)
        .run(GitRequest(arguments: [], directory: scratch))
      #expect(result.termination == .exit(0))
      let text = try #require(String(data: result.stdout, encoding: .utf8))
      var actual = Dictionary(
        uniqueKeysWithValues: text.split(separator: "\n").map {
          let parts = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          return (String(parts[0]), String(parts[1]))
        })
      // macOS may add this variable when launching a process.
      actual.removeValue(forKey: "__CF_USER_TEXT_ENCODING")
      var expected = inherited.filter { !$0.key.hasPrefix("GIT_") }
      expected.merge([
        "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1",
        "LC_ALL": "C",
        "GIT_SSH_COMMAND": "/usr/bin/ssh -o BatchMode=yes",
      ]) { _, fixed in fixed }
      #expect(actual == expected)
      #expect(result.stderr.isEmpty)
    }
  }

  @Test func inheritedEnvironmentCannotEnableLazyFetching() async throws {
    try await withScratchDirectory { scratch in
      let runner = SystemGitRunner(
        executable: "/usr/bin/env",
        environment: ["GIT_NO_LAZY_FETCH": "0"])
      let result = try await runner.run(GitRequest(arguments: [], directory: scratch))
      let text = try #require(String(bytes: result.stdout, encoding: .utf8))
      #expect(text.split(separator: "\n").contains("GIT_NO_LAZY_FETCH=1"))
    }
  }

  @Test(arguments: ["0", "1"])
  func defaultRequestsDoNotDisableLazyFetching(inherited: String) async throws {
    await withKnownIssue("#11: defaultRequestsDoNotDisableLazyFetching") {
      try await withScratchDirectory { scratch in
        let runner = SystemGitRunner(
          executable: "/usr/bin/env",
          environment: ["GIT_NO_LAZY_FETCH": inherited])
        let result = try await runner.run(.init(arguments: [], directory: scratch))
        let output = try #require(String(bytes: result.stdout, encoding: .utf8))
        #expect(!output.split(separator: "\n").contains { $0.hasPrefix("GIT_NO_LAZY_FETCH=") })
      }
    }
  }

  @Test func largeOutputCannotFillAPipe() async throws {
    try await withScratchDirectory { scratch in
      let script = scratch.appending(path: "git")
      let source =
        "#!/bin/sh\n"
        + "/usr/bin/awk 'BEGIN { for(i=0;i<20000;i++) print \"data\" }'\nprintf err >&2\n"
      try Data(source.utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let result = try await SystemGitRunner(executable: script.path).run(
        GitRequest(arguments: [], directory: scratch))
      #expect(result.termination == .exit(0))
      #expect(result.stdout == Data(String(repeating: "data\n", count: 20000).utf8))
      #expect(result.stderr == Data("err".utf8))
    }
  }

  @Test func timeoutKillsAChildIgnoringTermination() async throws {
    try await withScratchDirectory { scratch in
      let fifo = scratch.appending(path: "hold")
      try #require(mkfifo(fifo.path, 0o600) == 0)
      let script = scratch.appending(path: "git")
      // The marker confirms the handler was installed within the process deadline.
      // An ignored SIGTERM remains ignored across exec; cat blocks opening the FIFO.
      try Data("#!/bin/sh\ntrap '' TERM\nprintf ready\nexec /bin/cat \"$1\"\n".utf8).write(
        to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let result = try await SystemGitRunner(executable: script.path, killAfter: 0.01).run(
        GitRequest(arguments: [fifo.path], directory: scratch, timeout: 1))
      #expect(result.termination == .timedOut)
      #expect(result.stdout == Data("ready".utf8))
    }
  }

  @Test func deadlinesAreExplicitAndSpawnFailuresAreCoded() async throws {
    try await withScratchDirectory { scratch in
      #expect(GitRequest(arguments: ["fetch"], directory: scratch).timeout == 10)
      #expect(GitRequest(arguments: ["fetch"], directory: scratch, timeout: 60).timeout == 60)
      let request = GitRequest(arguments: [], directory: scratch)
      await #expect(throws: SeamError.gitUnavailable) {
        try await SystemGitRunner(executable: "git").run(request)
      }
      let fake = ScriptedGitRunner(script: [(request, .success(GitResult(termination: .exit(0))))])
      await #expect(throws: (any Error).self) {
        try await fake.run(GitRequest(arguments: ["wrong"], directory: scratch))
      }
      #expect(!fake.isExhausted)
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
        ? ScriptedGitRunner(script: [(request, .success(expected))])
        : SystemGitRunner(executable: script.path)
      #expect(try await runner.run(request) == expected)
    }
  }

  private enum Planted: Error {
    case spawn
  }

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
      let pidFile = scratch.appending(path: "child-pid")
      let source = "#!/bin/sh\n/bin/cat \"$1\" &\nprintf '%s' \"$!\" > \"$2\"\nprintf '%s' \"$!\"\n"
      try Data(source.utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let result = try await SystemGitRunner(executable: script.path).run(
        GitRequest(arguments: [fifo.path, pidFile.path], directory: scratch))
      let text = try String(contentsOf: pidFile, encoding: .utf8)
      let descendant = try #require(Int32(text))
      defer { kill(descendant, SIGKILL) }
      #expect(result.stdout == Data(text.utf8))
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
    }
  }
}
