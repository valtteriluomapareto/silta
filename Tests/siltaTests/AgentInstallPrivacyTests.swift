import Darwin
import Foundation
import SiltaTestSupport
import Testing

struct AgentInstallPrivacyTests {
  static let modes = [
    [], ["--json"], ["--quiet"], ["--quiet", "--json"], ["--verbose"], ["--verbose", "--json"],
  ]

  static func check(_ result: CLIResult, exit: Int32 = 0) {
    #expect(result.termination == .exit(exit))
    #expect(!(result.stdout + result.stderr).contains(AgentInstallRoundOneTests.sentinel))
    #expect(!(result.stdout + result.stderr).contains("Acme-private-metadata"))
  }

  static func checkLogs(_ scratch: URL) throws {
    let data = scratch.appending(path: "silta-home")
    guard let files = FileManager.default.enumerator(at: data, includingPropertiesForKeys: nil)
    else { return }
    for case let file as URL in files where file.pathExtension == "jsonl" {
      let log = try String(contentsOf: file, encoding: .utf8)
      #expect(!log.contains(AgentInstallRoundOneTests.sentinel))
      #expect(!log.contains("Acme-private-metadata"))
    }
  }

  static func wrapInstructions(in scratch: URL) throws {
    for path in [".codex/AGENTS.md", ".claude/CLAUDE.md"] {
      if path.hasPrefix(".claude") {
        _ = try AgentsInstallTests.apply(["install", "--claude"], in: scratch)
      }
      let owned = try AgentsInstallTests.read(path, in: scratch)
      try AgentsInstallTests.write(
        AgentInstallRoundOneTests.sentinel + owned + AgentInstallRoundOneTests.sentinel,
        path, in: scratch)
    }
  }

  @Test(arguments: modes)
  func successOutputsContainOnlyOwnedSpans(flags: [String]) throws {
    try withScratchDirectory { scratch in
      let original = try AgentInstallRoundOneTests.seeded(scratch)
      try Self.wrapInstructions(in: scratch)
      Self.check(try AgentsInstallTests.run(["install"] + flags, in: scratch))
      Self.check(try AgentsInstallTests.run(["install", "--dry-run"] + flags, in: scratch))
      Self.check(try AgentsInstallTests.run(["install", "--help"] + flags, in: scratch))
      let root = scratch.resolvingSymlinksInPath().appending(path: "silta-home").path
      let movedRoot = root + "/relocated"
      let moved = ["SILTA_HOME": movedRoot]
      let preview = try AgentsInstallTests.run(
        ["install", "--json"], in: scratch, environment: moved)
      Self.check(preview)
      let data = try AgentsInstallTests.data(preview)
      let changes = try #require(data["changes"] as? [[String: String]])
      #expect(
        changes.contains {
          $0["path"] == ".codex/config.toml" && $0["diff"]?.contains(movedRoot) == true
        })
      let token = try #require(data["token"] as? String)
      Self.check(try AgentsInstallTests.run(["install"] + flags, in: scratch, environment: moved))
      Self.check(
        try AgentsInstallTests.run(
          ["install", "--dry-run"] + flags, in: scratch, environment: moved))
      Self.check(
        try AgentsInstallTests.run(
          ["install", "--apply", token] + flags, in: scratch, environment: moved))
      let updated = try AgentsInstallTests.read(".codex/config.toml", in: scratch)
      let expected = original.replacingOccurrences(of: root, with: movedRoot)
      let normalize: (String) -> String = {
        $0.replacingOccurrences(
          of: #"# silta:begin [0-9a-f]{64}:"#,
          with: "# silta:begin <digest>:", options: .regularExpression)
      }
      #expect(normalize(updated) == normalize(expected))
      let remove = try AgentsInstallTests.run(["uninstall", "--json"], in: scratch)
      Self.check(remove)
      let removalToken = try #require(try AgentsInstallTests.data(remove)["token"] as? String)
      Self.check(try AgentsInstallTests.run(["uninstall"] + flags, in: scratch))
      Self.check(
        try AgentsInstallTests.run(["uninstall", "--apply", removalToken] + flags, in: scratch))
      #expect(
        try AgentsInstallTests.read(".codex/config.toml", in: scratch).hasSuffix(
          "\n[private]\napi_key = \"\(AgentInstallRoundOneTests.sentinel)\"\n"))
      #expect(original.contains(AgentInstallRoundOneTests.sentinel))
      try Self.checkLogs(scratch)
    }
  }

  static func damage(_ failure: String, in scratch: URL) throws {
    if failure == "toml" {
      let text = try AgentsInstallTests.read(".codex/config.toml", in: scratch)
      try AgentsInstallTests.write(
        text + "[private]\napi_key = \"Acme-private-round-one-sentinel\"\n",
        ".codex/config.toml", in: scratch)
    } else if failure == "edited" {
      let text = try AgentsInstallTests.read(".codex/AGENTS.md", in: scratch)
      try AgentsInstallTests.write(
        text.replacingOccurrences(of: "silta guide", with: "Acme edited"),
        ".codex/AGENTS.md", in: scratch)
    } else if failure == "metadata" {
      try AgentInstallMetadataTests.protect("xattr", in: scratch)
    } else if failure == "utf8" {
      try (Data([0xff]) + Data(AgentInstallRoundOneTests.sentinel.utf8)).write(
        to: scratch.appending(path: "home/.codex/config.toml"))
    }
  }

  @Test(
    arguments: modes,
    ["stale", "edited", "invalid", "io", "utf8", "metadata", "busy", "override", "toml"])
  func failuresDoNotExposePrivateConfiguration(flags: [String], failure: String) throws {
    try withScratchDirectory { scratch in
      _ = try AgentInstallRoundOneTests.seeded(scratch)
      var environment =
        failure == "io"
        ? ["SILTA_HOME": scratch.appending(path: "silta-home/failure").path] : [:]
      var args = ["install", "--codex"]
      var expected: Int32 = 6
      var lock: Int32 = -1
      defer { if lock >= 0 { close(lock) } }
      if failure == "busy" {
        lock = open(scratch.appending(path: "home").path, O_RDONLY | O_DIRECTORY)
        #expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
      } else if failure == "override" {
        environment["CODEX_HOME"] = scratch.appending(path: "other-config").path
        expected = 9
      } else if failure == "invalid" {
        args.append("--bad-option")
        expected = 1
      } else if failure == "io" {
        let preview = try AgentsInstallTests.run(
          args + ["--json"], in: scratch, environment: environment)
        Self.check(preview)
        args += ["--apply", try #require(try AgentsInstallTests.data(preview)["token"] as? String)]
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o500], ofItemAtPath: scratch.appending(path: "home/.codex").path)
        expected = 9
      } else if failure == "stale" {
        args += ["--apply", "stale-token"]
      }
      try Self.damage(failure, in: scratch)
      defer {
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: scratch.appending(path: "home/.codex").path)
        } catch { Issue.record(error) }
      }
      Self.check(
        try AgentsInstallTests.run(args + flags, in: scratch, environment: environment),
        exit: expected)
      try Self.checkLogs(scratch)
    }
  }
}
