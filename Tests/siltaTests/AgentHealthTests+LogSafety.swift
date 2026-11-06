import Foundation
import SiltaTestSupport
import Testing

extension AgentHealthTests {
  @Test(arguments: ["file-link", "directory-link", "hardlink"])
  func doctorNeverAppendsThroughLogAliases(_ kind: String) throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let directory = scratch.appending(path: "silta-home/log")
      let daily = directory.appending(path: "2026-11-06.jsonl")
      let outside = scratch.appending(path: "non-log")
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      let sentinel = outside.appending(path: "2026-11-06.jsonl")
      let bytes = Data("Acme configuration sentinel\n".utf8)
      try bytes.write(to: sentinel)
      if kind == "directory-link" {
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
      } else {
        if FileManager.default.fileExists(atPath: daily.path) {
          try FileManager.default.removeItem(at: daily)
        }
        if kind == "hardlink" {
          try FileManager.default.linkItem(at: sentinel, to: daily)
        } else {
          try FileManager.default.createSymbolicLink(at: daily, withDestinationURL: sentinel)
        }
      }
      let result = try SiltaBinary.run(
        ["doctor", "--install", "--json"], in: scratch, environment: env)
      #expect(result.termination == .exit(0))
      #expect(try Data(contentsOf: sentinel) == bytes)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["2026-11-06.jsonl"])
    }
  }

  @Test(arguments: [
    "missing-env", "malformed", "invalid-session", "invalid-actor", "stop-malformed",
    "stop-matching-actor",
  ])
  func actualEarlyHookFailureReplacesOlderHealthyEvidence(_ kind: String) throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      try Self.logs(Self.healthyHistory(), scratch)
      var hookEnvironment = env
      hookEnvironment["SILTA_NOW"] = "2026-11-06T11:00:00.000Z"
      if kind != "missing-env" {
        hookEnvironment["CLAUDE_ENV_FILE"] = scratch.appending(path: "exported").path
      }
      if kind == "invalid-actor" { hookEnvironment["SILTA_ACTOR"] = "AcmeUnloggedInvalidActor" }
      if kind == "stop-matching-actor" { hookEnvironment["SILTA_ACTOR"] = "agent:claude:one" }
      let command = kind.hasPrefix("stop-") ? "silta agents stop" : "silta agents session-start"
      let payload =
        ["malformed", "stop-malformed", "stop-matching-actor"].contains(kind)
        ? "{AcmeUnloggedPayload"
        : kind == "invalid-session"
          ? #"{"session_id":"Acme Unlogged Invalid Session"}"# : #"{"session_id":"two"}"#
      let result = try AgentsHookTests.hook(
        command, payload: payload, in: scratch, environment: hookEnvironment)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.isEmpty && result.stderr.isEmpty)
      let text = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2026-11-06.jsonl"), encoding: .utf8)
      let lines = text.split(separator: "\n")
      #expect(lines.count == 4)
      #expect(!text.contains("AcmeUnlogged") && !text.contains("Acme Unlogged"))
      let last = try GuideContractTests.object(String(try #require(lines.last)))
      #expect(last["command"] as? String == command)
      #expect(last["error_code"] as? String == "env")
      #expect(last["warnings"] as? [String] == ["hook_failed"])
      #expect(last["exit_code"] as? Int == 0)
      #expect(last["timestamp"] as? String == "2026-11-06T11:00:00.000Z")
      #expect(last["session_matches_actor"] == nil)
      let checks = try Self.checks(scratch, env)
      let id =
        kind.hasPrefix("stop-") ? "install.claude.last_stop" : "install.claude.session_start"
      #expect(try Self.check(id, in: checks)["status"] as? String == "warning")
      #expect(
        try Self.check("install.claude.session", in: checks)["status"] as? String == "warning")
    }
  }

  @Test func activeStopIsAnIntentionalQuietSkip() throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let history = try Self.healthyHistory()
      try Self.logs(history, scratch)
      let result = try AgentsHookTests.hook(
        "silta agents stop", payload: #"{"session_id":"one","stop_hook_active":true}"#, in: scratch,
        environment: env)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.isEmpty && result.stderr.isEmpty)
      let text = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2026-11-06.jsonl"), encoding: .utf8)
      #expect(text == history)
      #expect(
        try Self.check("install.claude.session", in: Self.checks(scratch, env))["status"] as? String
          == "pass")
    }
  }

  @Test(arguments: ["CLAUDE_CONFIG_DIR", "CODEX_HOME"], ["", "/", "///"])
  func configuredRootAliasesNeverBypassNoFollow(_ key: String, _ suffix: String) throws {
    try withScratchDirectory { scratch in
      var env = try Self.setup(scratch)
      let link = scratch.appending(path: "config-link")
      let name = key == "CODEX_HOME" ? ".codex" : ".claude"
      let target = scratch.appending(path: "home/" + name)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      env[key] = link.path + suffix
      let checks = try Self.checks(scratch, env)
      let id = key == "CODEX_HOME" ? "install.codex_root" : "install.skill"
      #expect(try Self.check(id, in: checks)["status"] as? String == "fail")
    }
  }

  static func healthyHistory() throws -> String {
    try entry("silta agents session-start")
      + entry("silta task ls", time: "10:01:00", propagated: true)
      + entry("silta agents stop", time: "10:02:00")
  }
}
