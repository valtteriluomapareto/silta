import CryptoKit
import Foundation
import SiltaTestSupport
import Testing

struct AgentCodexMarkersTests {
  static let path = ".codex/config.toml"
  static let tables = """

    [tui]

    [tui.model_availability_nux]

    [projects."/acme/platform"]
    trust_level = "trusted"
    """ + "\n"

  static func seeded(_ scratch: URL, original: String, suffix: String = tables) throws -> String {
    if !original.isEmpty { try AgentsInstallTests.write(original, path, in: scratch) }
    #expect(
      try AgentsInstallTests.apply(["install", "--codex"], in: scratch).termination == .exit(0))
    let installed = try AgentsInstallTests.read(path, in: scratch)
    let edited = installed.replacingOccurrences(of: "# silta:end\n", with: suffix + "# silta:end\n")
    try AgentsInstallTests.write(edited, path, in: scratch)
    return edited
  }

  @Test(arguments: ["install", "uninstall"])
  func codexOwnTablesInsideMarkersRemainUsable(operation: String) throws {
    try withScratchDirectory { scratch in
      let original = "cli_auth_credentials_store = \"file\"\n"
      let edited = try Self.seeded(scratch, original: original)
      let before = try AgentInstallRoundTwoTests.snapshot(scratch)
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run([operation, "--codex", "--json"], in: scratch))
      #expect(try AgentInstallRoundTwoTests.snapshot(scratch) == before)
      let token = try #require(preview["token"] as? String)
      #expect(
        try AgentsInstallTests.run([operation, "--codex", "--apply", token], in: scratch)
          .termination == .exit(0))
      let expected =
        operation == "install"
        ? edited.replacingOccurrences(
          of: Self.tables + "# silta:end\n", with: "# silta:end\n" + Self.tables)
        : original + Self.tables
      #expect(
        Data(try AgentsInstallTests.read(Self.path, in: scratch).utf8) == Data(expected.utf8))
    }
  }

  static func bytes(_ scratch: URL) throws -> Data {
    try Data(contentsOf: scratch.appending(path: "home/" + path))
  }

  @Test(arguments: ["install", "uninstall"])
  func quotedModelNuxRemainsByteExact(operation: String) throws {
    try withScratchDirectory { scratch in
      let suffix = Self.tables.replacingOccurrences(
        of: "[tui.model_availability_nux]\n",
        with: "[tui.model_availability_nux]\n\"acme.model\" = 1\n")
      let original = "cli_auth_credentials_store = \"file\"\n"
      let edited = try Self.seeded(scratch, original: original, suffix: suffix)
      #expect(
        try AgentsInstallTests.apply([operation, "--codex"], in: scratch).termination == .exit(0))
      let expected =
        operation == "install"
        ? edited.replacingOccurrences(of: suffix + "# silta:end\n", with: "# silta:end\n" + suffix)
        : original + suffix
      #expect(try Self.bytes(scratch) == Data(expected.utf8))
    }
  }

  @Test(
    arguments: [
      "", "cli_auth_credentials_store = \"file\"\n",
      "cli_auth_credentials_store = \"file\"",
      "[\"sandbox_workspace_write\"]\nnetwork_access = false\n",
    ],
    ["install", "update", "uninstall"])
  func foreignSuffixIsByteExact(original: String, operation: String) throws {
    try withScratchDirectory { scratch in
      let suffix = String(Self.tables.dropFirst()) + "\n# Acme-private-e\u{301}-é  \t\n"
      let edited = try Self.seeded(scratch, original: original, suffix: suffix)
      let config = scratch.appending(path: "home/" + Self.path)
      try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: config.path)
      let before = try AgentInstallRoundTwoTests.snapshot(scratch)
      let command = operation == "uninstall" ? "uninstall" : "install"
      let root = scratch.resolvingSymlinksInPath().appending(path: "silta-home").path
      let env = operation == "update" ? ["SILTA_HOME": root + "/relocated"] : [:]
      let result = try AgentsInstallTests.run(
        [command, "--codex", "--json"], in: scratch, environment: env)
      let data = try AgentsInstallTests.data(result)
      let changes = try #require(data["changes"] as? [[String: String]])
      let diff = try #require(changes.first { $0["path"] == Self.path }?["diff"])
      #expect(diff.contains("Preserve \(suffix.utf8.count) unowned TOML bytes in place"))
      #expect(!result.stdout.contains("Acme-private") && !result.stdout.contains("/acme/platform"))
      #expect(!diff.isEmpty)
      if operation == "uninstall", !original.isEmpty, !original.hasSuffix("\n") {
        #expect(diff.contains("# Retain the separating newline."))
      }
      #expect(try AgentInstallRoundTwoTests.snapshot(scratch) == before)
      let token = try #require(data["token"] as? String)
      #expect(
        try AgentsInstallTests.run(
          [command, "--codex", "--apply", token], in: scratch, environment: env
        ).termination == .exit(0))
      let separator = !original.isEmpty && !original.hasSuffix("\n") ? "\n" : ""
      let uninstalled =
        original.hasPrefix("[\"sandbox_workspace_write\"]")
        ? "[\"sandbox_workspace_write\"]\n" + suffix + "network_access = false\n"
        : original + separator + suffix
      if operation != "uninstall" {
        try Self.checkReinstall(scratch, edited: edited, suffix: suffix, operation: operation)
      }
      #expect(try Self.bytes(scratch) == Data(uninstalled.utf8))
      let mode =
        try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions]
        as? NSNumber
      #expect(mode?.intValue == 0o640)
      #expect(
        try AgentsInstallTests.apply(["install", "--codex"], in: scratch).termination == .exit(0))
      #expect(
        try AgentsInstallTests.apply(["uninstall", "--codex"], in: scratch).termination == .exit(0))
      #expect(try Self.bytes(scratch) == Data(uninstalled.utf8))
      try Self.checkLogPrivacy(scratch)
    }
  }

}

extension AgentCodexMarkersTests {
  static func checkReinstall(_ scratch: URL, edited: String, suffix: String, operation: String)
    throws
  {
    let root = scratch.resolvingSymlinksInPath().appending(path: "silta-home").path
    let env = operation == "update" ? ["SILTA_HOME": root + "/relocated"] : [:]
    let after = try Self.bytes(scratch)
    let moved = edited.replacingOccurrences(
      of: suffix + "# silta:end\n", with: "# silta:end\n" + suffix)
    let normalize: (String) -> Data = {
      Data(
        $0.replacingOccurrences(
          of: #"# silta:begin [0-9a-f]{64}:"#, with: "# silta:begin <digest>:",
          options: .regularExpression
        ).utf8)
    }
    let expected =
      operation == "update"
      ? moved.replacingOccurrences(of: root, with: root + "/relocated") : moved
    #expect(normalize(try #require(String(bytes: after, encoding: .utf8))) == normalize(expected))
    #expect(
      try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch, environment: env))[
          "changes"] as? [[String: String]] == [])
    #expect(
      try AgentsInstallTests.apply(["uninstall", "--codex"], in: scratch).termination
        == .exit(0))
  }

  static func checkLogPrivacy(_ scratch: URL) throws {
    if let logs = FileManager.default.enumerator(
      at: scratch.appending(path: "silta-home"), includingPropertiesForKeys: nil)
    {
      for case let file as URL in logs where file.pathExtension == "jsonl" {
        let log = try String(contentsOf: file, encoding: .utf8)
        #expect(!log.contains("Acme-private") && !log.contains("/acme/platform"))
      }
    }
  }
}

extension AgentCodexMarkersTests {

  @Test(arguments: ["install", "uninstall"], [false, true])
  func markerPreviewContract(operation: String, json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try Self.seeded(scratch, original: "cli_auth_credentials_store = \"file\"\n")
      let result = try AgentsInstallTests.run(
        [operation, "--codex"] + (json ? ["--json"] : []), in: scratch)
      #expect(result.termination == .exit(0))
      let diff: String
      if json {
        let changes = try #require(
          try AgentsInstallTests.data(result)["changes"] as? [[String: String]])
        diff = try #require(changes.first { $0["path"] == Self.path }?["diff"])
      } else {
        let section = try #require(result.stdout.range(of: Self.path + "\n"))
        let tail = String(result.stdout[section.upperBound...])
        let apply = try #require(tail.range(of: "\nApply:"))
        diff = String(tail[..<apply.lowerBound])
      }
      #expect(diff.contains("Preserve \(Self.tables.utf8.count) unowned TOML bytes in place"))
      let normalized = diff.replacingOccurrences(
        of: "Preserve \(Self.tables.utf8.count)", with: "Preserve <bytes>"
      )
      .replacingOccurrences(of: #"[0-9a-f]{64}"#, with: "<digest>", options: .regularExpression)
      .replacingOccurrences(
        of: #"writable_roots = \["[^"]*"\]"#,
        with: "writable_roots = [\"<root>\"]", options: .regularExpression)
      Golden.forTests().check(normalized + "\n", "agents-codex-markers-\(operation).txt")
    }
  }

  @Test(arguments: ["install", "uninstall"])
  func foreignOnlyEditInvalidatesPreview(operation: String) throws {
    try withScratchDirectory { scratch in
      let original = try Self.seeded(scratch, original: "model = \"acme\"\n")
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run([operation, "--codex", "--json"], in: scratch))
      let token = try #require(preview["token"] as? String)
      try AgentsInstallTests.write(
        original.replacingOccurrences(of: "trusted", with: "untrusted"), Self.path, in: scratch)
      let before = try AgentInstallRoundTwoTests.snapshot(scratch)
      let result = try AgentsInstallTests.run(
        [operation, "--codex", "--apply", token, "--json"], in: scratch)
      #expect(result.termination == .exit(6))
      #expect(result.stdout.contains("Preview changed"))
      #expect(try AgentInstallRoundTwoTests.snapshot(scratch) == before)
    }
  }

  @Test(
    arguments: ["install", "uninstall"],
    ["grant", "origin", "scope", "nested", "duplicate", "malformed"])
  func ambiguousRecoveryRefuses(operation: String, fault: String) throws {
    try withScratchDirectory { scratch in
      let original = try Self.seeded(scratch, original: "model = \"acme\"\n")
      let edited: String
      switch fault {
      case "grant":
        edited = original.replacingOccurrences(
          of: "writable_roots = [\"", with: "writable_roots = [\"/tampered")
      case "origin": edited = original.replacingOccurrences(of: ":keep\n", with: ":new\n")
      case "scope":
        edited = original.replacingOccurrences(
          of: Self.tables, with: "network_access = false\n" + Self.tables)
      case "nested":
        edited = original.replacingOccurrences(
          of: Self.tables, with: "# silta:begin nested\n" + Self.tables)
      case "duplicate": edited = original + "# silta:end\n"
      default: edited = original.replacingOccurrences(of: "[projects.", with: "[projects..")
      }
      try AgentsInstallTests.write(edited, Self.path, in: scratch)
      try AgentInstallRoundTwoTests.refusesWithoutWrites(
        [operation], in: scratch, reason: "edited or ambiguous")
    }
  }

  @Test(arguments: [
    "[projects.\"/acme/path.with.dots\"]\ntrust_level = \"trusted\"\n",
    "[projects.\"/acme/quote\\\"and\\\\slash\"]\ntrust_level = \"trusted\"\n",
    "[projects.\"a.b\"]\ntrust_level = \"trusted\"\n[projects.a.b]\ntrust_level = \"untrusted\"\n",
    "[tui.model_availability_nux]\n\"acme.model\" = 1\n\"acme=other\" = 2\n",
  ])
  func firstInstallPreservesQuotedTables(tables: String) throws {
    try withScratchDirectory { scratch in
      let original = "cli_auth_credentials_store = \"file\"\n" + tables
      try AgentsInstallTests.write(original, Self.path, in: scratch)
      #expect(
        try AgentsInstallTests.apply(["install", "--codex"], in: scratch).termination == .exit(0))
      #expect(
        try AgentsInstallTests.apply(["uninstall", "--codex"], in: scratch).termination == .exit(0))
      #expect(try Self.bytes(scratch) == Data(original.utf8))
    }
  }

  @Test(
    arguments: [
      "[tui]\n[\"tui\"]\n",
      "[tui]\n[\"tu\\u0069\"]\n",
      "[tui]\n\"model\" = 1\nmodel = 2\n",
      "\"tui\" = 1\n[tui]\nvalue = 2\n",
      "[projects.\"a.b\"]\n[projects.a.b]\n[projects.\"a.b\"]\n",
      "[\"sandbox_workspace_write\"]\nwritable_roots = [\"/acme\"]\n",
      "[\"sandbox_workspace_write\"]\n\"writable_roots\" = [\"/acme\"]\n",
      "[\"sandbox_workspace_write\".other]\nvalue = 1\n",
    ], ["install", "uninstall"])
  func decodedNamespaceConflictsRefuse(tables: String, operation: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(tables, Self.path, in: scratch)
      if operation == "uninstall", tables.contains("sandbox_workspace_write") {
        #expect(
          try AgentsInstallTests.apply([operation, "--codex"], in: scratch).termination == .exit(0))
        #expect(try Self.bytes(scratch) == Data(tables.utf8))
        return
      }
      try AgentInstallRoundTwoTests.refusesWithoutWrites(
        [operation], in: scratch, reason: "edited or ambiguous")
    }
  }

  @Test(arguments: ["install", "uninstall"])
  func sealedNonGrantPrefixIsNotOwnership(operation: String) throws {
    try withScratchDirectory { scratch in
      let content = "[sandbox_workspace_write]\nnetwork_access = true\n"
      let digest = SHA256.hash(data: Data(("keep:" + content).utf8))
        .map { String(format: "%02x", $0) }.joined()
      let original = "\n# silta:begin \(digest):keep\n" + content + Self.tables + "# silta:end\n"
      try AgentsInstallTests.write(original, Self.path, in: scratch)
      try AgentInstallRoundTwoTests.refusesWithoutWrites(
        [operation], in: scratch, reason: "edited or ambiguous")
    }
  }

  @Test(arguments: ["install", "uninstall"])
  func quotedUserTableScopeChangesRefuse(operation: String) throws {
    try withScratchDirectory { scratch in
      let original = try Self.seeded(
        scratch, original: "[\"sandbox_workspace_write\"]\nnetwork_access = false\n")
      try AgentsInstallTests.write(
        original.replacingOccurrences(
          of: "[\"sandbox_workspace_write\"]", with: "[\"private_scope\"]"), Self.path, in: scratch)
      try AgentInstallRoundTwoTests.refusesWithoutWrites(
        [operation], in: scratch, reason: "edited or ambiguous")
    }
  }
}
