import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct AgentHealthTests {
  static let now = ["SILTA_NOW": "2026-11-06T12:00:00.000Z"]

  static func setup(_ scratch: URL) throws -> [String: String] {
    _ = try SiltaBinary.run(["init"], in: scratch, environment: now)
    #expect(
      try AgentsInstallTests.apply(["install", "--stop-hook"], in: scratch, environment: now)
        .termination == .exit(0))
    let bin = scratch.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for (name, path) in [
      ("claude", "claude/versions/2.1.314"),
      ("codex", "Caskroom/codex/0.166.0/bin/codex"),
      ("opencode", "Cellar/opencode/1.19.5/bin/opencode"),
    ] {
      let target = scratch.appending(path: path)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("#!/bin/sh\necho launched > '\(scratch.appending(path: "launched").path)'\n".utf8)
        .write(to: target)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
      try FileManager.default.createSymbolicLink(
        at: bin.appending(path: name), withDestinationURL: target)
    }
    try FileManager.default.createSymbolicLink(
      at: bin.appending(path: "silta"), withDestinationURL: SiltaBinary.url())
    return now.merging(["PATH": bin.path + ":/usr/bin:/bin"]) { _, new in new }
  }

  static func checks(_ scratch: URL, _ env: [String: String]) throws -> [[String: Any]] {
    let result = try SiltaBinary.run(
      ["doctor", "--install", "--json"], in: scratch, environment: env)
    let object = try GuideContractTests.object(result.stdout)
    return try #require((object["data"] as? [String: Any])?["checks"] as? [[String: Any]])
  }

  static func check(_ id: String, in checks: [[String: Any]]) throws -> [String: Any] {
    try #require(checks.first { $0["id"] as? String == id })
  }

  static func logs(_ text: String, _ scratch: URL) throws {
    let path = scratch.appending(path: "silta-home/log/2026-11-06.jsonl")
    try Data(text.utf8).write(to: path)
  }

  static func entry(
    _ command: String, session: String = "one", time: String = "10:00:00", exit: Int = 0,
    warning: String? = nil, error: String? = nil, propagated: Bool? = nil
  ) throws -> String {
    var value: [String: Any] = [
      "timestamp": "2026-11-06T\(time).000Z", "command": command,
      "actor": "agent:claude:\(session)", "exit_code": exit,
      "milliseconds": 37, "flags": [], "warnings": warning.map { [$0] } ?? [],
    ]
    if let error { value["error_code"] = error }
    if let propagated { value["session_matches_actor"] = propagated }
    return try #require(
      String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8)) + "\n"
  }

  @Test func intactPiecesAndMetadataVersionsNeverLaunchHarnesses() throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let checks = try Self.checks(scratch, env)
      for id in [
        "install.path", "install.skill", "install.claude.instructions", "install.codex_marker",
        "install.codex_root", "install.hook", "install.claude.stop", "install.claude.version",
        "install.codex.version",
      ] {
        #expect(try Self.check(id, in: checks)["status"] as? String == "pass", "\(id)")
      }
      let version = try Self.check("install.claude.version", in: checks)["message"] as? String ?? ""
      #expect(version.contains("2.1.314"))
      #expect(version.contains("2026-11-06"))
      #expect(version.contains("metadata"))
      #expect(
        try Self.check("install.opencode.version", in: checks)["status"] as? String == "warning")
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "launched").path))
      for check in checks
      where (check["id"] as? String)?.hasPrefix("install.") == true
        && (check["status"] as? String) != "pass"
      {
        #expect(!(check["next"] as? [String] ?? []).isEmpty)
      }
    }
  }

  @Test(arguments: ["skill", "claude", "codex", "root", "start", "stop", "missing", "symlink"])
  func damagedPieceIsIndependentAndReadOnly(_ fault: String) throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      let paths = [
        "skill": ".claude/skills/silta/SKILL.md", "claude": ".claude/CLAUDE.md",
        "codex": ".codex/AGENTS.md", "root": ".codex/config.toml", "start": ".claude/settings.json",
        "stop": ".claude/settings.json", "missing": ".codex/AGENTS.md",
        "symlink": ".codex/AGENTS.md",
      ]
      let path = try #require(paths[fault])
      let url = scratch.appending(path: "home/" + path)
      if fault == "missing" || fault == "symlink" {
        try FileManager.default.removeItem(at: url)
        if fault == "symlink" {
          try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: scratch.appending(path: "sentinel"))
        }
      } else {
        let old = try String(contentsOf: url, encoding: .utf8)
        let edited =
          fault == "root"
          ? "[sandbox_workspace_write]\nwritable_roots = []\n"
          : old.replacingOccurrences(
            of: fault == "start"
              ? "Silta SessionStart" : fault == "stop" ? "Silta Stop" : "silta guide",
            with: "Acme fault")
        try Data(edited.utf8).write(to: url)
      }
      let before = try snapshot(scratch.appending(path: "home"))
      let checks = try Self.checks(scratch, env)
      let ids = [
        "skill": "install.skill", "claude": "install.claude.instructions",
        "codex": "install.codex_marker", "root": "install.codex_root", "start": "install.hook",
        "stop": "install.claude.stop", "missing": "install.codex_marker",
        "symlink": "install.codex_marker",
      ]
      let result = try Self.check(try #require(ids[fault]), in: checks)
      #expect(result["status"] as? String != "pass")
      #expect(!(result["next"] as? [String] ?? []).isEmpty)
      #expect(try snapshot(scratch.appending(path: "home")) == before)
      #expect(try Self.check("install.claude.version", in: checks)["status"] as? String == "pass")
    }
  }

  @Test func latestHookEvidenceAndPropagation() throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      try Self.logs(
        Self.entry("silta agents session-start")
          + Self.entry("silta task ls", time: "10:01:00", propagated: true)
          + Self.entry("silta agents stop", time: "10:02:00"), scratch)
      var checks = try Self.checks(scratch, env)
      for id in [
        "install.claude.session_start", "install.claude.last_stop", "install.claude.session",
      ] {
        #expect(try Self.check(id, in: checks)["status"] as? String == "pass")
      }
      let message =
        try Self.check("install.claude.last_stop", in: checks)["message"] as? String ?? ""
      #expect(
        message.contains("2026-11-06T10:02:00.000Z") && message.contains("exit 0")
          && message.contains("37 ms"))
      let startMessage =
        try Self.check("install.claude.session_start", in: checks)["message"] as? String ?? ""
      #expect(startMessage.contains("2026-11-06T10:00:00.000Z"))
      #expect(startMessage.contains("exit 0"))
      #expect(startMessage.contains("37 ms"))
      try Self.logs(
        Self.entry("silta agents session-start", session: "two", time: "11:00:00"), scratch)
      checks = try Self.checks(scratch, env)
      #expect(
        try Self.check("install.claude.session", in: checks)["status"] as? String == "warning")
    }
  }

  @Test(arguments: [
    "exit", "warning", "error", "legacy", "negative", "new-session", "orphan-stop", "foreign-hook",
    "malformed",
    "future",
  ])
  func unknownOrFailedEvidenceNeverPasses(_ fault: String) throws {
    try withScratchDirectory { scratch in
      let env = try Self.setup(scratch)
      var log = try Self.entry(
        "silta agents session-start", exit: fault == "exit" ? 4 : 0,
        warning: fault == "warning" ? "hook_timeout" : nil, error: fault == "error" ? "env" : nil)
      log += try Self.entry(
        "silta task ls", time: "10:01:00", propagated: fault == "legacy" ? nil : true)
      if fault == "negative" {
        log += try Self.entry("silta task ls", time: "10:02:00", propagated: false)
      }
      if fault == "new-session" {
        log += try Self.entry("silta agents session-start", session: "two", time: "11:00:00")
      }
      if fault == "orphan-stop" {
        log += try Self.entry("silta agents stop", session: "two", time: "11:00:00")
      }
      if fault == "foreign-hook" {
        log += try Self.entry("silta agents stop", session: "two", time: "11:00:00")
          .replacingOccurrences(of: "agent:claude:", with: "agent:codex:")
      }
      if fault == "malformed" { log += "{broken\n" }
      if fault == "future" { log += try Self.entry("silta agents session-start", time: "23:00:00") }
      try Self.logs(log, scratch)
      let checks = try Self.checks(scratch, env)
      let id =
        fault == "foreign-hook"
        ? "install.claude.last_stop"
        : ["exit", "warning", "error", "malformed", "future"].contains(fault)
          ? "install.claude.session_start" : "install.claude.session"
      let result = try Self.check(id, in: checks)
      #expect(result["status"] as? String != "pass")
      #expect(!(result["next"] as? [String] ?? []).isEmpty)
      if fault == "foreign-hook" {
        #expect((result["message"] as? String)?.contains("2026-11-06T11:00:00.000Z") == true)
      }
    }
  }

  @Test func versionDriftAndOverridesRemainIndependent() throws {
    try withScratchDirectory { scratch in
      var env = try Self.setup(scratch)
      env["CLAUDE_CONFIG_DIR"] = scratch.appending(path: "isolated-claude").path
      let binary = scratch.appending(path: "bin/claude")
      try FileManager.default.removeItem(at: binary)
      let newer = scratch.appending(path: "claude/versions/2.1.319")
      try FileManager.default.copyItem(
        at: scratch.appending(path: "claude/versions/2.1.314"), to: newer)
      try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: newer)
      let checks = try Self.checks(scratch, env)
      #expect(
        try Self.check("install.claude.version", in: checks)["status"] as? String == "warning")
      #expect(try Self.check("install.skill", in: checks)["status"] as? String != "pass")
      #expect(try Self.check("install.codex_root", in: checks)["status"] as? String == "pass")
      for id in ["install.hook", "install.claude.stop"] {
        let hook = try Self.check(id, in: checks)
        #expect(hook["next_by"] as? String == "human")
        let next = try #require(hook["next"] as? [String])
        #expect(next.contains { $0.contains("isolated-claude/settings.json") })
        #expect(!next.contains { $0.hasPrefix("silta agents install --claude --") })
      }
    }
  }

  @Test func relativePATHMatchesShellResolution() throws {
    try withScratchDirectory { scratch in
      var env = try Self.setup(scratch)
      env["PATH"] = "../bin:/usr/bin:/bin"
      let checks = try Self.checks(scratch, env)
      #expect(try Self.check("install.path", in: checks)["status"] as? String == "pass")
      #expect(try Self.check("install.codex.version", in: checks)["status"] as? String == "pass")
    }
  }

  func snapshot(_ root: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let enumerator = try #require(
      FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
    for case let file as URL in enumerator {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isRegularFile == true && values.isSymbolicLink != true {
        result[file.path] = try Data(contentsOf: file)
      }
    }
    return result
  }
}
