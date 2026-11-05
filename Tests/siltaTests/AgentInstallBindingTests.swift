import Foundation
import SiltaTestSupport
import Testing

struct AgentInstallBindingTests {
  @Test func changedModeInvalidatesPreviewWithoutWrites() throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write("Acme instructions", ".codex/AGENTS.md", in: scratch)
      let file = scratch.appending(path: "home/.codex/AGENTS.md")
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch))
      try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
      let result = try AgentsInstallTests.run(
        ["install", "--codex", "--apply", try #require(preview["token"] as? String), "--json"],
        in: scratch)
      #expect(result.termination == .exit(6))
      #expect(try AgentsInstallTests.read(".codex/AGENTS.md", in: scratch) == "Acme instructions")
      #expect(
        !FileManager.default.fileExists(
          atPath: scratch.appending(path: "home/.codex/config.toml").path))
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
    }
  }

  @Test func identicalFilesInDifferentHomeRejectOldPreview() throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write("Acme instructions", ".codex/AGENTS.md", in: scratch)
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch))
      let other = scratch.appending(path: "other-home")
      try FileManager.default.copyItem(at: scratch.appending(path: "home"), to: other)
      let result = try AgentsInstallTests.run(
        ["install", "--codex", "--apply", try #require(preview["token"] as? String), "--json"],
        in: scratch,
        environment: ["HOME": other.path])
      #expect(result.termination == .exit(6))
      for home in [scratch.appending(path: "home"), other] {
        #expect(
          try String(contentsOf: home.appending(path: ".codex/AGENTS.md"), encoding: .utf8)
            == "Acme instructions")
        #expect(
          !FileManager.default.fileExists(atPath: home.appending(path: ".codex/config.toml").path))
      }
    }
  }
}

extension AgentInstallBindingTests {
  @Test func changedCompatibleGroupInvalidatesPreview() throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write("model = \"Acme\"\n", ".codex/config.toml", in: scratch)
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch))
      for path in [".codex/config.toml", ".codex"] {
        #expect(
          try AgentInstallMetadataTests.command(
            "/usr/bin/chgrp", ["everyone", scratch.appending(path: "home/" + path).path],
            in: scratch
          ).termination == .exit(0))
      }
      let before = try AgentInstallMetadataTests.snapshot(scratch)
      let result = try AgentsInstallTests.run(
        ["install", "--codex", "--apply", try #require(preview["token"] as? String), "--json"],
        in: scratch)
      #expect(result.termination == .exit(6))
      #expect(try AgentInstallMetadataTests.snapshot(scratch) == before)
    }
  }
}
