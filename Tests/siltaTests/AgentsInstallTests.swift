import Foundation
import SiltaTestSupport
import Testing

struct AgentsInstallTests {
  static func run(
    _ args: [String], in scratch: URL, environment: [String: String] = [:]
  ) throws -> CLIResult {
    try SiltaBinary.run(["agents"] + args, in: scratch, environment: environment)
  }

  static func data(_ result: CLIResult) throws -> [String: Any] {
    #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
    return try #require(try GuideContractTests.object(result.stdout)["data"] as? [String: Any])
  }

  static func apply(_ args: [String], in scratch: URL) throws -> CLIResult {
    let preview = try data(run(args + ["--json"], in: scratch))
    return try run(args + ["--apply", try #require(preview["token"] as? String)], in: scratch)
  }

  static func write(_ text: String, _ path: String, in scratch: URL) throws {
    let url = scratch.appending(path: "home/" + path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  static func read(_ path: String, in scratch: URL) throws -> String {
    try String(contentsOf: scratch.appending(path: "home/" + path), encoding: .utf8)
  }

  @Test func previewAndApplyBindExactBytes() throws {
    try withScratchDirectory { scratch in
      try Self.write("Acme instructions without newline", ".codex/AGENTS.md", in: scratch)
      let args = ["install", "--codex"]
      let preview = try Self.data(Self.run(args + ["--json"], in: scratch))
      let token = try #require(preview["token"] as? String)
      #expect(preview["applied"] as? Bool == false)
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.claude").path))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.codex/config.toml").path))
      #expect(try Self.read(".codex/AGENTS.md", in: scratch) == "Acme instructions without newline")
      try Self.write("Acme changed", ".codex/AGENTS.md", in: scratch)
      let stale = try Self.run(args + ["--apply", token, "--json"], in: scratch)
      #expect(stale.termination == .exit(6))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.codex/config.toml").path))
      #expect(try Self.apply(args, in: scratch).termination == .exit(0))
      #expect(try Self.read(".codex/AGENTS.md", in: scratch).hasPrefix("Acme changed"))
      #expect(try Self.data(Self.run(args + ["--json"], in: scratch))["changes"] as? [[String: String]] == [])
      #expect(try Self.apply(["uninstall", "--codex"], in: scratch).termination == .exit(0))
      #expect(try Self.read(".codex/AGENTS.md", in: scratch) == "Acme changed")
    }
  }

  @Test func selectionAndSkillParity() throws {
    try withScratchDirectory { scratch in
      try Self.write("Acme poison", ".codex/config.toml", in: scratch)
      #expect(try Self.apply(["install", "--claude"], in: scratch).termination == .exit(0))
      let skill = try Self.read(".claude/skills/silta/SKILL.md", in: scratch)
      #expect(skill.hasPrefix("---\nname: silta\ndescription:"))
      let guide = try SiltaBinary.run(["guide"], in: scratch)
      #expect(skill.contains(guide.stdout))
      #expect(try Self.read(".codex/config.toml", in: scratch) == "Acme poison")
      #expect(try Self.apply(["uninstall", "--claude"], in: scratch).termination == .exit(0))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.claude/skills/silta/SKILL.md").path))
    }
  }

  @Test func ownershipSurvivesRelocationAndRefusesEdits() throws {
    try withScratchDirectory { scratch in
      #expect(try Self.apply(["install", "--codex"], in: scratch).termination == .exit(0))
      let config = try Self.read(".codex/config.toml", in: scratch)
      #expect(config.contains(scratch.appending(path: "silta-home").resolvingSymlinksInPath().path))
      let env = ["SILTA_HOME": scratch.appending(path: "other-data").path]
      let preview = try Self.data(Self.run(["uninstall", "--codex", "--json"], in: scratch, environment: env))
      #expect(try Self.run(["uninstall", "--codex", "--apply", try #require(preview["token"] as? String)], in: scratch, environment: env).termination == .exit(0))
      #expect(try Self.apply(["install", "--codex"], in: scratch).termination == .exit(0))
      let changed = try Self.read(".codex/AGENTS.md", in: scratch).replacingOccurrences(of: "silta guide", with: "Acme changed")
      try Self.write(changed, ".codex/AGENTS.md", in: scratch)
      let result = try Self.run(["uninstall", "--codex", "--json"], in: scratch)
      #expect(result.termination == .exit(6))
      #expect(try Self.read(".codex/config.toml", in: scratch) == config)
    }
  }

  @Test(arguments: ["symlink", "ancestor", "fifo", "hardlink", "utf8", "marker", "roots", "override"])
  func unsafeInputsRefuseBeforeAnyWrite(kind: String) throws {
    try withScratchDirectory { scratch in
      try Self.write("", ".codex/AGENTS.md", in: scratch)
      let url = scratch.appending(path: "home/.codex/AGENTS.md")
      var env: [String: String] = [:]
      switch kind {
      case "symlink", "ancestor":
        let target = kind == "ancestor" ? url.deletingLastPathComponent() : url
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: scratch)
      case "fifo":
        try FileManager.default.removeItem(at: url)
        #expect(try SiltaBinary.runProcess(URL(filePath: "/usr/bin/mkfifo"), [url.path], in: scratch).termination == .exit(0))
      case "hardlink": try FileManager.default.linkItem(at: url, to: scratch.appending(path: "alias"))
      case "utf8": try Data([0xff]).write(to: url)
      case "marker": try Self.write("<!-- silta:begin broken -->\n", ".codex/AGENTS.md", in: scratch)
      case "roots": try Self.write("[sandbox_workspace_write]\nwritable_roots = [\"/acme\"]\n", ".codex/config.toml", in: scratch)
      default: env["CODEX_HOME"] = scratch.path
      }
      let result = try Self.run(["install", "--json"], in: scratch, environment: env)
      #expect(result.termination != .exit(0))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "home/.claude").path))
      let error = try #require(try GuideContractTests.object(result.stdout)["error"] as? [String: Any])
      let next = try #require(error["next"] as? [String])
      #expect(!next.isEmpty)
      for command in next where command.hasPrefix("silta ") {
        #expect(try SiltaBinary.run(command.split(separator: " ").dropFirst().map(String.init), in: scratch).termination == .exit(0))
      }
    }
  }

  @Test func privateConfigStaysOffOutput() throws {
    try withScratchDirectory { scratch in
      let original = "model = \"Acme-private-sentinel\"\n[other]\nvalue = 42\n"
      try Self.write(original, ".codex/config.toml", in: scratch)
      try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: scratch.appending(path: "home/.codex/config.toml").path)
      let preview = try Self.run(["install", "--codex", "--json"], in: scratch)
      #expect(!preview.stdout.contains("Acme-private-sentinel"))
      #expect(try Self.apply(["install", "--codex"], in: scratch).termination == .exit(0))
      let attrs = try FileManager.default.attributesOfItem(atPath: scratch.appending(path: "home/.codex/config.toml").path)
      #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o640)
      #expect(try Self.apply(["uninstall", "--codex"], in: scratch).termination == .exit(0))
      #expect(try Self.read(".codex/config.toml", in: scratch) == original)
    }
  }
}
