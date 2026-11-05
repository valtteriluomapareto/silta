import Darwin
import Foundation
import SiltaTestSupport
import Testing

struct AgentHookRecoveryTests {
  @Test(arguments: [
    #"{"hooks":{}}"#, #"{"hooks":{"SessionStart":[]}}"#,
    #"{"hooks":{"Future":{"opaque":true},"SessionStart":[]}}"#,
  ])
  func emptyUserContainersSurvive(text: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(text, ".claude/settings.json", in: scratch)
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      #expect(
        try AgentsInstallTests.apply(["uninstall", "--claude"], in: scratch).termination == .exit(0)
      )
      let restored = try AgentsInstallTests.read(".claude/settings.json", in: scratch)
      #expect(restored == text + "\n")
    }
  }

  @Test func partialExportStaysValidAndWithinTheBound() throws {
    try withScratchDirectory { scratch in
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      let command = try AgentsHookTests.command("SessionStart", in: scratch)
      let file = scratch.appending(path: "claude-env")
      let original = Data("export ACME=kept".utf8)
      try original.write(to: file)
      let script = """
        import os, resource, signal, subprocess, sys
        def limit():
          signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
          resource.setrlimit(resource.RLIMIT_FSIZE, (24, 24))
        result = subprocess.run(['/bin/sh', '-c', sys.argv[1]], env=os.environ,
          input=b'{"session_id":"acme-session"}', capture_output=True,
          preexec_fn=limit, restore_signals=False)
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
        sys.exit(result.returncode)
        """
      let path = try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/python3"), ["-c", script, command],
        in: scratch, environment: ["PATH": path, "CLAUDE_ENV_FILE": file.path])
      #expect(result.termination == .exit(0) && result.stdout.isEmpty && result.stderr.isEmpty)
      #expect(try Data(contentsOf: file).starts(with: original))
      let after = try Data(contentsOf: file)
      #expect(after.dropFirst(original.count).allSatisfy { $0 == 10 })
      let syntax = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-n", file.path], in: scratch)
      #expect(syntax.termination == .exit(0))
      let sourced = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        ["-c", ". \"$0\"; printf '%s:%s' \"$ACME\" \"${SILTA_SESSION-unset}\"", file.path],
        in: scratch)
      #expect(sourced.stdout == "kept:unset")
      _ = try AgentsHookTests.hook(
        command, payload: #"{"session_id":"acme-session"}"#, in: scratch,
        environment: ["CLAUDE_ENV_FILE": file.path])
      let retry = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        ["-c", ". \"$0\"; printf '%s:%s' \"$ACME\" \"$SILTA_SESSION\"", file.path], in: scratch)
      #expect(retry.stdout == "kept:acme-session")
      let large = Data(repeating: 32, count: 1_048_576)
      try large.write(to: file)
      _ = try AgentsHookTests.hook(
        command, payload: #"{"session_id":"acme"}"#, in: scratch,
        environment: ["CLAUDE_ENV_FILE": file.path])
      #expect(try Data(contentsOf: file) == large)
    }
  }

  @Test func environmentFileLockSerializesExports() throws {
    try withScratchDirectory { scratch in
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      let command = try AgentsHookTests.command("SessionStart", in: scratch)
      let file = scratch.appending(path: "claude-env")
      let original = Data("export ACME=kept".utf8)
      try original.write(to: file)
      let fd = open(file.path, O_WRONLY)
      #expect(fd >= 0)
      defer { close(fd) }
      #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
      _ = try AgentsHookTests.hook(
        command, payload: #"{"session_id":"acme"}"#, in: scratch,
        environment: ["CLAUDE_ENV_FILE": file.path])
      #expect(try Data(contentsOf: file) == original)
      #expect(flock(fd, LOCK_UN) == 0)
      _ = try AgentsHookTests.hook(
        command, payload: #"{"session_id":"acme"}"#, in: scratch,
        environment: ["CLAUDE_ENV_FILE": file.path])
      #expect(try Data(contentsOf: file).count > original.count)
    }
  }
}

extension AgentHookRecoveryTests {
  @Test(arguments: [0, 1]) func environmentExportRenderedSizeBoundary(excess: Int) throws {
    try withScratchDirectory { scratch in
      _ = try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch)
      let command = try AgentsHookTests.command("SessionStart", in: scratch)
      let file = scratch.appending(path: "claude-env")
      let line = Data("\nexport SILTA_SESSION='acme'\n".utf8)
      let original = Data(repeating: 32, count: 1_048_576 - line.count + excess)
      try original.write(to: file)
      let result = try AgentsHookTests.hook(
        command, payload: #"{"session_id":"acme"}"#, in: scratch,
        environment: ["CLAUDE_ENV_FILE": file.path])
      #expect(result.termination == .exit(0) && result.stdout.isEmpty && result.stderr.isEmpty)
      #expect(try Data(contentsOf: file) == (excess == 0 ? original + line : original))
    }
  }
}
