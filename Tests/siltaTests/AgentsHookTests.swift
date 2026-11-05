import Darwin
import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

struct AgentsHookTests {
  static func command(_ event: String, in scratch: URL) throws -> String {
    let text = try AgentsInstallTests.read(".claude/settings.json", in: scratch)
    let root = try GuideContractTests.object(text)
    let hooks = try #require(root["hooks"] as? [String: Any])
    let entries = try #require(hooks[event] as? [[String: Any]]).flatMap {
      $0["hooks"] as? [[String: Any]] ?? []
    }
    return try #require(
      entries.compactMap { $0["command"] as? String }.first { $0.contains("silta:") })
  }

  static func hook(
    _ command: String, payload: String, in scratch: URL,
    environment: [String: String] = [:], cwd: URL? = nil
  ) throws -> CLIResult {
    let input = scratch.appending(path: "event.json")
    try Data(payload.utf8).write(to: input)
    let path = try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
    return try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"),
      ["-c", "exec < " + shellWord(input.path) + "; exec /bin/sh -c " + shellWord(command)],
      in: scratch, cwd: cwd,
      environment: ["PATH": path].merging(environment) { _, new in new })
  }

  @Test func hookSettingsRoundTripAndSelection() throws {
    try withScratchDirectory { scratch in
      let original = """
        {"permissions":{"allow":["Bash(acme)"]},
        "private":{"nested":[null,true,42,"Acme sentinel"]},
        "hooks":{"Future":{"opaque":true},
        "SessionStart":[{"hooks":[{"type":"command","command":"echo Acme"}]}]}}
        """
      try AgentsInstallTests.write(original, ".claude/settings.json", in: scratch)
      let preview = try AgentsInstallTests.run(
        ["install", "--claude", "--hook", "--json"], in: scratch)
      #expect(!preview.stdout.contains("Acme sentinel"))
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      #expect(try Self.command("SessionStart", in: scratch).contains("agents session-start"))
      #expect(
        try AgentsInstallTests.read(".claude/settings.json", in: scratch).contains("echo Acme"))
      #expect(
        try AgentsInstallTests.data(
          AgentsInstallTests.run(["install", "--claude", "--hook", "--json"], in: scratch))[
            "changes"] as? [[String: String]] == [])
      #expect(
        try AgentsInstallTests.apply(["uninstall", "--claude"], in: scratch).termination == .exit(0)
      )
      let restored = try GuideContractTests.object(
        AgentsInstallTests.read(".claude/settings.json", in: scratch))
      #expect(
        NSDictionary(dictionary: restored)
          == NSDictionary(dictionary: try GuideContractTests.object(original)))
      let invalid = try AgentsInstallTests.run(
        ["install", "--codex", "--hook", "--json"], in: scratch)
      #expect(invalid.termination == .exit(1))
      #expect(invalid.stdout.contains("silta agents install --help"))
    }
  }

  @Test(arguments: ["not json", #"{"hooks":[]}"#, #"{"hooks":{"SessionStart":false}}"#])
  func malformedSettingsRefuseBeforeWrites(text: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(text, ".claude/settings.json", in: scratch)
      let result = try AgentsInstallTests.run(["install", "--hook", "--json"], in: scratch)
      #expect(result.termination == .exit(6))
      #expect(try AgentsInstallTests.read(".claude/settings.json", in: scratch) == text)
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.codex").path))
    }
  }

}

extension AgentsHookTests {
  @Test(arguments: [false, true])
  func hookSettingsRetainFileProvenance(existed: Bool) throws {
    try withScratchDirectory { scratch in
      if existed { try AgentsInstallTests.write("{}", ".claude/settings.json", in: scratch) }
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      let invalid = try AgentsInstallTests.run(
        ["uninstall", "--claude", "--hook", "--json"], in: scratch)
      #expect(invalid.termination == .exit(1))
      #expect(invalid.stdout.contains("silta agents uninstall --help"))
      #expect(
        try AgentsInstallTests.apply(["uninstall", "--claude"], in: scratch).termination == .exit(0)
      )
      if existed {
        #expect(
          try GuideContractTests.object(
            AgentsInstallTests.read(".claude/settings.json", in: scratch)
          ).isEmpty)
      } else {
        #expect(
          !FileManager.default.fileExists(
            atPath: scratch.appending(path: "home/.claude/settings.json").path))
      }
    }
  }

  @Test(arguments: [".claude/settings.json", ".claude/CLAUDE.md"])
  func renderedFilesStayWithinReadableLimit(path: String) throws {
    try withScratchDirectory { scratch in
      let body = String(repeating: "A", count: 1_048_550)
      let original = path.hasSuffix(".json") ? "{\"private\":\"" + body + "\"}" : body
      #expect(original.utf8.count <= 1_048_576)
      try AgentsInstallTests.write(original, path, in: scratch)
      let result = try AgentsInstallTests.run(
        ["install", "--claude", "--hook", "--json"], in: scratch)
      #expect(result.termination == .exit(6))
      #expect(try AgentsInstallTests.read(path, in: scratch) == original)
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "home/.claude/skills").path)
      )
    }
  }

  @Test func ownedHookDiffMatchesSpec() throws {
    try withScratchDirectory { scratch in
      #expect(
        try AgentsInstallTests.apply(["install", "--claude"], in: scratch).termination == .exit(0))
      let result = try AgentsInstallTests.run(
        ["install", "--claude", "--hook", "--json"], in: scratch)
      let data = try AgentsInstallTests.data(result)
      let token = try #require(data["token"] as? String)
      Golden.forTests().check(
        result.stdout.replacingOccurrences(of: token, with: "<token>"),
        "agents-install-hook.json")
    }
  }

  @Test func hookExportsValidatedSessionAndPreservesExports() throws {
    try withScratchDirectory { scratch in
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      let command = try Self.command("SessionStart", in: scratch)
      let file = scratch.appending(path: "claude-env")
      try Data("export ACME=kept".utf8).write(to: file)
      let env = ["CLAUDE_ENV_FILE": file.path]
      let result = try Self.hook(
        command, payload: #"{"session_id":"acme-session"}"#, in: scratch, environment: env)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.isEmpty && result.stderr.isEmpty)
      let shell = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        ["-c", ". " + shellWord(file.path) + "; printf '%s:%s' \"$ACME\" \"$SILTA_SESSION\""],
        in: scratch)
      #expect(shell.stdout == "kept:acme-session")
      let before = try Data(contentsOf: file)
      for payload in [
        #"{"session_id":"x'; touch injected; #"}"#, #"{"session_id":""}"#, "{}", "not json",
      ] {
        let refused = try Self.hook(command, payload: payload, in: scratch, environment: env)
        #expect(refused.termination == .exit(0))
        #expect(refused.stdout.isEmpty && refused.stderr.isEmpty)
        #expect(try Data(contentsOf: file) == before)
      }
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "work/injected").path))
      #expect(
        try Self.hook(command, payload: #"{"session_id":"acme"}"#, in: scratch).stdout.isEmpty)
      let link = scratch.appending(path: "env-link")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
      #expect(
        try Self.hook(
          command, payload: #"{"session_id":"acme"}"#, in: scratch,
          environment: ["CLAUDE_ENV_FILE": link.path]
        ).stdout.isEmpty)
      #expect(try Data(contentsOf: file) == before)
    }
  }

  @Test func installedHookRunsBriefAndSharesSubsequentActor() throws {
    try withScratchDirectory { scratch in
      let fixture = WhereCommandTests()
      let repo = try fixture.setup(scratch)
      try fixture.git(["checkout", "-q", "api"], repo, scratch)
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      let file = scratch.appending(path: "claude-env")
      try Data().write(to: file)
      let command = try Self.command("SessionStart", in: scratch)
      let result = try Self.hook(
        command, payload: #"{"session_id":"acme-session"}"#, in: scratch,
        environment: ["CLAUDE_ENV_FILE": file.path], cwd: repo)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("acme"))
      #expect(result.stderr.isEmpty)
      let logs = scratch.appending(path: "silta-home/log")
      let files = try FileManager.default.contentsOfDirectory(
        at: logs, includingPropertiesForKeys: nil)
      let entries = try files.filter { $0.pathExtension == "jsonl" }.flatMap {
        try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init)
      }.map(GuideContractTests.object)
      let entry = try #require(
        entries.first { $0["command"] as? String == "silta agents session-start" })
      #expect(entry["actor"] as? String == "agent:claude:acme-session")
      let script =
        ". " + shellWord(file.path) + "; " + shellWord(try SiltaBinary.url().path)
        + " --ws acme task add 'Acme work' --start --app none --json"
      let subsequent = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", script], in: scratch, cwd: repo,
        environment: ["CLAUDECODE": "1"])
      #expect(subsequent.termination == .exit(0))
      let show = try SiltaBinary.run(
        ["--ws", "acme", "task", "show", "AC-1", "--json"], in: scratch)
      #expect(show.stdout.contains("agent:claude:acme-session"))
    }
  }

  @Test(arguments: [
    #"{"hooks":{},"hooks":{}}"#, #"{"hooks":{},"\u0068ooks":{}}"#,
    #"{"unknown":9007199254740993}"#, #"{"unknown":0.12345678901234567890123}"#,
  ])
  func ambiguousJSONRefusesBeforeWrites(text: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(text, ".claude/settings.json", in: scratch)
      let result = try AgentsInstallTests.run(["install", "--hook", "--json"], in: scratch)
      #expect(result.termination == .exit(6))
      #expect(try AgentsInstallTests.read(".claude/settings.json", in: scratch) == text)
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.codex").path))
    }
  }

  @Test(arguments: ["edited", "duplicate", "mixed", "origin"])
  func editedOwnedSettingsRefuse(kind: String) throws {
    try withScratchDirectory { scratch in
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      var root = try GuideContractTests.object(
        AgentsInstallTests.read(".claude/settings.json", in: scratch))
      var hooks = try #require(root["hooks"] as? [String: Any])
      var groups = try #require(hooks["SessionStart"] as? [[String: Any]])
      var handlers = try #require(groups[0]["hooks"] as? [[String: Any]])
      if kind == "duplicate" {
        groups.append(groups[0])
      } else {
        if kind == "mixed" {
          handlers.append(["type": "command", "command": "echo Acme"])
        } else {
          let command = try #require(handlers[0]["command"] as? String)
          handlers[0]["command"] =
            kind == "origin"
            ? command.replacingOccurrences(of: ":new:", with: ":keep:") : command + " edited"
        }
        groups[0]["hooks"] = handlers
      }
      hooks["SessionStart"] = groups
      root["hooks"] = hooks
      let text =
        String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8) ?? ""
      try AgentsInstallTests.write(text, ".claude/settings.json", in: scratch)
      #expect(
        try AgentsInstallTests.run(["uninstall", "--claude", "--json"], in: scratch).termination
          == .exit(6))
      #expect(try AgentsInstallTests.read(".claude/settings.json", in: scratch) == text)
    }
  }

  @Test func staleSettingsAndUnselectedSettingsStaySafe() throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write("{}", ".claude/settings.json", in: scratch)
      let args = ["install", "--hook"]
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(args + ["--json"], in: scratch))
      try AgentsInstallTests.write("{} ", ".claude/settings.json", in: scratch)
      let stale = try AgentsInstallTests.run(
        args + ["--apply", try #require(preview["token"] as? String), "--json"], in: scratch)
      #expect(stale.termination == .exit(6))
      #expect(stale.stdout.contains("silta agents install --hook"))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.codex").path))
      try AgentsInstallTests.write("not JSON", ".claude/settings.json", in: scratch)
      #expect(
        try AgentsInstallTests.apply(["install", "--claude"], in: scratch).termination == .exit(0))
      #expect(try AgentsInstallTests.read(".claude/settings.json", in: scratch) == "not JSON")
    }
  }

}

extension AgentsHookTests {
  @Test func hookBoundsHeldOpenAndOversizedInput() throws {
    try withScratchDirectory { scratch in
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      let command = try Self.command("SessionStart", in: scratch)
      let script = """
        import os, signal, subprocess, sys
        child = subprocess.Popen(['/bin/sh', '-c', sys.argv[1]], stdin=subprocess.PIPE,
          stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        status = 124
        try:
          status = child.wait(timeout=2.5)
        except subprocess.TimeoutExpired:
          pass
        finally:
          try:
            os.killpg(child.pid, signal.SIGKILL)
          except ProcessLookupError:
            pass
          out, err = child.communicate(timeout=2)
        sys.stdout.buffer.write(out)
        sys.stderr.buffer.write(err)
        sys.exit(status)
        """
      let path = try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
      let held = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/python3"), ["-c", script, command],
        in: scratch, environment: ["PATH": path], timeout: 6)
      #expect(held.termination == .exit(0) && held.stdout.isEmpty && held.stderr.isEmpty)
      let logs = scratch.appending(path: "silta-home/log")
      let files = try FileManager.default.contentsOfDirectory(
        at: logs, includingPropertiesForKeys: nil)
      let entries = try files.filter { $0.pathExtension == "jsonl" }.flatMap {
        try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init)
      }.map(GuideContractTests.object)
      let timeout = try #require(
        entries.first {
          ($0["warnings"] as? [String])?.contains("hook_timeout") == true
        })
      #expect(timeout["command"] as? String == "silta agents session-start")
      #expect((timeout["flags"] as? [String] ?? []).isEmpty)
      let file = scratch.appending(path: "claude-env")
      try Data().write(to: file)
      let large = try Self.hook(
        command, payload: String(repeating: " ", count: 70_000) + #"{"session_id":"acme"}"#,
        in: scratch, environment: ["CLAUDE_ENV_FILE": file.path])
      #expect(large.termination == .exit(0) && large.stdout.isEmpty && large.stderr.isEmpty)
      #expect(try Data(contentsOf: file).isEmpty)
    }
  }

  @Test(arguments: [
    "relative", "symlink", "ancestor", "hardlink", "fifo", "directory", "readonly", "oversized",
  ])
  func unsafeEnvironmentFilesStayUnchanged(kind: String) throws {
    try withScratchDirectory { scratch in
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      let command = try Self.command("SessionStart", in: scratch)
      let file = scratch.appending(path: "claude-env")
      try Data("export ACME=kept\n".utf8).write(to: file)
      var target = file.path
      var fifo: Int32 = -1
      defer { if fifo >= 0 { Darwin.close(fifo) } }
      switch kind {
      case "relative": target = "claude-env"
      case "symlink", "ancestor":
        let link = scratch.appending(path: "alias")
        try FileManager.default.createSymbolicLink(
          at: link, withDestinationURL: kind == "ancestor" ? scratch : file)
        target = kind == "ancestor" ? link.appending(path: "claude-env").path : link.path
      case "hardlink":
        try FileManager.default.linkItem(at: file, to: scratch.appending(path: "alias"))
      case "fifo":
        target = scratch.appending(path: "pipe").path
        #expect(
          try SiltaBinary.runProcess(URL(filePath: "/usr/bin/mkfifo"), [target], in: scratch)
            .termination == .exit(0))
        fifo = open(target, O_RDWR | O_NONBLOCK)
        #expect(fifo >= 0)
      case "directory": target = scratch.path
      case "readonly":
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
      default: try Data(repeating: 65, count: 1_048_577).write(to: file)
      }
      let before = try Data(contentsOf: file)
      let result = try Self.hook(
        command, payload: #"{"session_id":"acme"}"#, in: scratch,
        environment: ["CLAUDE_ENV_FILE": target])
      #expect(result.termination == .exit(0) && result.stdout.isEmpty && result.stderr.isEmpty)
      #expect(try Data(contentsOf: file) == before)
      if fifo >= 0 {
        var bytes = [UInt8](repeating: 0, count: 256)
        #expect(Darwin.read(fifo, &bytes, bytes.count) <= 0)
      }
    }
  }
}
