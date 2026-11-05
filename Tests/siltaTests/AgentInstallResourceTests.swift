import Foundation
import SiltaTestSupport
import Testing

struct AgentInstallResourceTests {
  @Test func writeLimitFailureNamesTheTargetAndCause() throws {
    try withScratchDirectory { scratch in
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch))
      let script = """
        import os, resource, signal, subprocess, sys
        def limit():
          signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
          resource.setrlimit(resource.RLIMIT_FSIZE, (128, 128))
        result = subprocess.run([sys.argv[1], 'agents', 'install', '--codex', '--apply',
          sys.argv[2], '--json'], env=os.environ, capture_output=True,
          preexec_fn=limit, restore_signals=False)
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
        sys.exit(result.returncode)
        """
      let result = try SiltaBinary.runProcess(URL(filePath: "/usr/bin/python3"),
        ["-c", script, try SiltaBinary.url().path, try #require(preview["token"] as? String)],
        in: scratch)
      #expect(result.termination == .exit(9))
      withKnownIssue("#17: uncoded write failures must retain the active target and safe cause") {
        #expect(result.stdout.contains(".codex/AGENTS.md"))
        #expect(result.stdout.contains("file size limit"))
      }
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.codex/AGENTS.md").path))
      #expect(try AgentsInstallTests.apply(["install", "--codex"], in: scratch).termination == .exit(0))
    }
  }
}
