import Darwin
import Foundation
import SiltaTestSupport
import Testing

struct AgentHookRecoveryTests {
  @Test(arguments: [#"{"hooks":{}}"#, #"{"hooks":{"SessionStart":[]}}"#])
  func emptyUserContainersSurvive(text: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(text, ".claude/settings.json", in: scratch)
      #expect(try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination == .exit(0))
      #expect(try AgentsInstallTests.apply(["uninstall", "--claude"], in: scratch).termination == .exit(0))
      let restored = try AgentsInstallTests.read(".claude/settings.json", in: scratch)
      withKnownIssue("#17: preserve empty user hook containers") {
        #expect(restored == text + "\n")
      }
    }
  }

  @Test func partialExportStaysValidAndWithinTheBound() throws {
    try withScratchDirectory { scratch in
      #expect(try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination == .exit(0))
      let command = try AgentsHookTests.command("SessionStart", in: scratch)
      let file = scratch.appending(path: "claude-env")
      let original = Data("export ACME=kept".utf8)
      try original.write(to: file)
      let script = """
        import os, resource, signal, subprocess, sys
        def limit():
          signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
          resource.setrlimit(resource.RLIMIT_FSIZE, (24, 24))
        result = subprocess.run(['/bin/sh', '-c', 'exec ' + sys.argv[1]], env=os.environ,
          input=b'{"session_id":"acme-session"}', capture_output=True,
          preexec_fn=limit, restore_signals=False)
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
        sys.exit(result.returncode)
        """
      let path = try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
      let result = try SiltaBinary.runProcess(URL(filePath: "/usr/bin/python3"), ["-c", script, command],
        in: scratch, environment: ["PATH": path, "CLAUDE_ENV_FILE": file.path])
      #expect(result.termination == .exit(0) && result.stdout.isEmpty && result.stderr.isEmpty)
      #expect(try Data(contentsOf: file).starts(with: original))
      let syntax = try SiltaBinary.runProcess(URL(filePath: "/bin/sh"), ["-n", file.path], in: scratch)
      withKnownIssue("#17: a partial export must not corrupt later shell sourcing") {
        #expect(syntax.termination == .exit(0))
      }
      let large = Data(repeating: 32, count: 1_048_576)
      try large.write(to: file)
      _ = try AgentsHookTests.hook(command, payload: #"{"session_id":"acme"}"#, in: scratch,
        environment: ["CLAUDE_ENV_FILE": file.path])
      withKnownIssue("#17: bound the resulting environment file") { () throws in
        #expect(try Data(contentsOf: file) == large)
      }
    }
  }
}
