import Foundation
import SiltaTestSupport
import Testing

struct AgentInstallMetadataTests {
  static let paths = [
    ".claude/skills/silta/SKILL.md", ".claude/CLAUDE.md", ".codex/AGENTS.md", ".codex/config.toml",
  ]

  static func command(_ name: String, _ args: [String], in scratch: URL) throws -> CLIResult {
    try SiltaBinary.runProcess(URL(filePath: name), args, in: scratch)
  }

  static func snapshot(_ scratch: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for path in paths + ["", ".claude", ".claude/skills", ".claude/skills/silta", ".codex"] {
      let file = scratch.appending(path: "home/" + path)
      var directory = ObjCBool(false)
      guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory) else {
        result[path] = "absent"
        continue
      }
      let bytes =
        directory.boolValue ? "directory" : try Data(contentsOf: file).base64EncodedString()
      let permissions = try command("/bin/ls", ["-ldneO", file.path], in: scratch)
      let attributes = try command("/usr/bin/xattr", ["-l", file.path], in: scratch)
      #expect(permissions.termination == .exit(0) && attributes.termination == .exit(0))
      result[path] = bytes + permissions.stdout + attributes.stdout
    }
    return result
  }

  static func protect(_ kind: String, in scratch: URL) throws {
    let file = scratch.appending(path: "home/.codex/config.toml")
    let result: CLIResult
    switch kind {
    case "acl":
      result = try command("/bin/chmod", ["+a", "user:nobody deny read", file.path], in: scratch)
    case "write-acl":
      result = try command(
        "/bin/chmod",
        ["+a", "everyone deny write", scratch.appending(path: "home/.codex/AGENTS.md").path],
        in: scratch)
    case "xattr":
      result = try command(
        "/usr/bin/xattr", ["-w", "com.acme.silta-security", "Acme-private-metadata", file.path],
        in: scratch)
    case "special": result = try command("/bin/chmod", ["1644", file.path], in: scratch)
    case "ownership": result = try command("/usr/bin/chgrp", ["everyone", file.path], in: scratch)
    case "flags": result = try command("/usr/bin/chflags", ["nodump", file.path], in: scratch)
    default:
      result = try command(
        "/bin/chmod",
        [
          "+a", "everyone allow read,file_inherit,directory_inherit",
          file.deletingLastPathComponent().path,
        ], in: scratch)
    }
    #expect(result.termination == .exit(0), "\(result.stderr)")
  }

  @Test(
    arguments: ["acl", "write-acl", "xattr", "special", "flags", "inherited", "ownership"],
    [false, true])
  func securityMetadataRefusesBeforeAnySelectedWrite(kind: String, afterPreview: Bool) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(
        "model = \"Acme-private-metadata\"\n", ".codex/config.toml", in: scratch)
      try AgentsInstallTests.write("Acme instructions", ".codex/AGENTS.md", in: scratch)
      var token: String?
      if afterPreview {
        token = try #require(
          try AgentsInstallTests.data(AgentsInstallTests.run(["install", "--json"], in: scratch))[
            "token"] as? String)
      }
      try Self.protect(kind, in: scratch)
      let before = try Self.snapshot(scratch)
      var result = try AgentsInstallTests.run(
        ["install", "--json"] + (token.map { ["--apply", $0] } ?? []), in: scratch)
      if result.termination == .exit(0), token == nil {
        let apply = try #require(try AgentsInstallTests.data(result)["token"] as? String)
        result = try AgentsInstallTests.run(["install", "--apply", apply, "--json"], in: scratch)
      }
      let after = try Self.snapshot(scratch)
      #expect(result.termination == .exit(6) && before == after)
      if kind == "xattr", !afterPreview {
        Golden.forTests().check(result.stdout, "agents-install-metadata.json")
      }
    }
  }
}
