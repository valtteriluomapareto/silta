import Foundation
import SiltaTestSupport
import Testing

struct AgentHookRoundOneTests {
  @Test(arguments: [
    "missing", "nonexecutable", "failure", "crash", "success", "line", "text", "empty",
  ])
  func installedCommandContainsExecutableFailures(kind: String) throws {
    try withScratchDirectory { scratch in
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      let command = try AgentsHookTests.command("SessionStart", in: scratch)
      let bin = scratch.appending(path: "bin")
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      if kind != "missing" {
        let body: String
        switch kind {
        case "success": body = "printf 'Acme brief\\n\\n'"
        case "line": body = "printf 'Acme brief\\n'"
        case "text": body = "printf 'Acme λ %%%% brief.'"
        case "empty": body = ":"
        case "crash": body = "printf 'Acme partial'; printf 'Acme diagnostic' >&2; kill -SEGV $$"
        default: body = "printf 'Acme partial'; printf 'Acme diagnostic' >&2; exit 9"
        }
        let file = bin.appending(path: "silta")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes(
          [.posixPermissions: kind == "nonexecutable" ? 0o600 : 0o700], ofItemAtPath: file.path)
      }
      let expected =
        kind == "success"
        ? "Acme brief\n\n"
        : kind == "line" ? "Acme brief\n" : kind == "text" ? "Acme λ %% brief." : ""
      let run: () throws -> Void = {
        let result = try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"), ["-c", command], in: scratch,
          environment: ["PATH": bin.path + ":/usr/bin:/bin"])
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        #expect(result.stdout == expected)
      }
      try run()
    }
  }

  @Test(
    arguments: [false, true], ["absent", "{}", #"{"hooks":{}}"#, #"{"hooks":{"SessionStart":[]}}"#])
  func exactLegacyCommandCanUpgradeOrUninstall(uninstall: Bool, initial: String) throws {
    try withScratchDirectory { scratch in
      if initial != "absent" {
        try AgentsInstallTests.write(initial, ".claude/settings.json", in: scratch)
      }
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      let command = try AgentsHookTests.command("SessionStart", in: scratch)
      let marker = try #require(command.range(of: "# silta:session-start:v1:"))
      let legacy = "silta agents session-start " + command[marker.lowerBound...]
      var root = try GuideContractTests.object(
        AgentsInstallTests.read(".claude/settings.json", in: scratch))
      var hooks = try #require(root["hooks"] as? [String: Any])
      var groups = try #require(hooks["SessionStart"] as? [[String: Any]])
      var handlers = try #require(groups[0]["hooks"] as? [[String: Any]])
      handlers[0]["command"] = legacy
      groups[0]["hooks"] = handlers
      hooks["SessionStart"] = groups
      root["hooks"] = hooks
      let bytes = try JSONSerialization.data(withJSONObject: root)
      try AgentsInstallTests.write(
        try #require(String(data: bytes, encoding: .utf8)), ".claude/settings.json", in: scratch)
      #expect(
        try AgentsInstallTests.apply(
          uninstall ? ["uninstall", "--claude"] : ["install", "--claude", "--hook"], in: scratch
        ).termination == .exit(0))
      if !uninstall {
        #expect(try AgentsHookTests.command("SessionStart", in: scratch) != legacy)
      }
    }
  }

  @Test(arguments: [
    #"{"hooks":{"SessionStart":[],"SessionStart":[]}}"#,
    #"{"private":{"key":"Acme first","\u006bey":"Acme second"}}"#,
    #"{"private":[{"nested":{"key":1,"key":2}}]}"#,
  ])
  func nestedDuplicateJSONRefusesBeforeWrites(text: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(text, ".claude/settings.json", in: scratch)
      let result = try AgentsInstallTests.run(["install", "--hook", "--json"], in: scratch)
      #expect(result.termination == .exit(6))
      #expect(!result.stdout.contains("Acme first") && !result.stdout.contains("Acme second"))
      #expect(result.stderr.isEmpty)
      #expect(result.stdout.contains("silta agents install --hook"))
      #expect(try AgentsInstallTests.read(".claude/settings.json", in: scratch) == text)
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.codex").path))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "home/.claude/skills").path)
      )
    }
  }

  @Test func sameKeysInSeparateObjectsRemainValid() throws {
    try withScratchDirectory { scratch in
      let text = #"{"private":[{"key":1},{"key":2}]}"#
      try AgentsInstallTests.write(text, ".claude/settings.json", in: scratch)
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      #expect(
        try AgentsInstallTests.apply(["uninstall", "--claude"], in: scratch).termination == .exit(0)
      )
      let restored = try GuideContractTests.object(
        AgentsInstallTests.read(".claude/settings.json", in: scratch))
      #expect(NSDictionary(dictionary: restored).isEqual(to: try GuideContractTests.object(text)))
    }
  }

  @Test func environmentFileOutsideHomeAndTemporaryRootsIsUntouched() throws {
    try withScratchDirectory { scratch in
      let directory = ScenarioRunner.repository.appending(
        path: "artifacts/env-file-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }  // Best-effort fixture cleanup.
      let file = directory.appending(path: "acme-env")
      let before = Data("export ACME=kept\n".utf8)
      try before.write(to: file)
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      let command = try AgentsHookTests.command("SessionStart", in: scratch)
      for existed in [true, false] {
        if !existed { try FileManager.default.removeItem(at: file) }
        let result = try AgentsHookTests.hook(
          command, payload: #"{"session_id":"acme"}"#, in: scratch,
          environment: ["CLAUDE_ENV_FILE": file.path])
        #expect(result.termination == .exit(0) && result.stdout.isEmpty && result.stderr.isEmpty)
        if existed {
          #expect(try Data(contentsOf: file) == before)
        } else {
          #expect(!FileManager.default.fileExists(atPath: file.path))
        }
      }
    }
  }
}
