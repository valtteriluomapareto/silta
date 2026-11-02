import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

struct GitRunnerTests {
  @Test(arguments: [false, true]) func gitContract(scripted: Bool) async throws {
    try await withScratchDirectory { scratch in
      let request = GitRequest(arguments: ["rev-parse", "--is-inside-work-tree"], directory: scratch)
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
      let initialized = try await runner.run(GitRequest(arguments: ["init", "-q"], directory: scratch))
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
      try Data("#!/bin/sh\n/usr/bin/env\nprintf err >&2\n/usr/bin/awk 'BEGIN { for(i=0;i<20000;i++) print \"data\" }'\n".utf8)
        .write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let result = try await SystemGitRunner(executable: script.path).run(
        GitRequest(arguments: [], directory: scratch))
      #expect(result.termination == .exit(0))
      let text = String(decoding: result.stdout, as: UTF8.self)
      #expect(text.contains("GIT_TERMINAL_PROMPT=0\n"))
      #expect(text.contains("GIT_OPTIONAL_LOCKS=0\n"))
      #expect(text.contains("LC_ALL=C\n"))
      #expect(!text.contains("SILTA_"))
      #expect(!text.contains("GIT_CONFIG"))
      #expect(text.components(separatedBy: "data\n").count == 20001)
      #expect(result.stderr == Data("err".utf8))
    }
  }

  @Test func timeoutKillsAChildIgnoringTermination() async throws {
    try await withScratchDirectory { scratch in
      let script = scratch.appending(path: "git")
      // No timing-based readiness assumption: the shell installs its handler before spinning.
      try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let result = try await SystemGitRunner(executable: script.path, killAfter: 0).run(
        GitRequest(arguments: [], directory: scratch, timeout: 0.1))
      #expect(result.termination == .timedOut)
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
}
