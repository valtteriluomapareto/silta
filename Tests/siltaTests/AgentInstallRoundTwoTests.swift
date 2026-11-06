import Foundation
import SiltaTestSupport
import Testing

struct AgentInstallRoundTwoTests {
  static let limit = 1_048_576
  static let paths = [
    ".claude/skills/silta/SKILL.md", ".claude/CLAUDE.md", ".codex/AGENTS.md", ".codex/config.toml",
  ]
  static let privateNote = "Acme-private-existing-table note"
  static let table = "[sandbox_workspace_write]\n"

  struct FileState: Equatable {
    let bytes: Data
    let metadata: [UInt64]
  }

  static func snapshot(_ scratch: URL) throws -> [String: FileState] {
    var files: [String: FileState] = [:]
    for path in paths {
      let file = scratch.appending(path: "home/" + path)
      if FileManager.default.fileExists(atPath: file.path) {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let metadata = try [
          FileAttributeKey.posixPermissions, .ownerAccountID, .groupOwnerAccountID,
        ].map { key throws -> UInt64 in
          try #require(attributes[key] as? NSNumber).uint64Value
        }
        files[path] = FileState(bytes: try Data(contentsOf: file), metadata: metadata)
      }
    }
    return files
  }

  static func refusesWithoutWrites(_ args: [String], in scratch: URL, reason: String) throws {
    let before = try snapshot(scratch)
    let preview = try AgentsInstallTests.run(args + ["--json"], in: scratch)
    let root = try GuideContractTests.object(preview.stdout)
    let token =
      (root["data"] as? [String: Any])?["token"] as? String ?? String(repeating: "0", count: 64)
    let apply = try AgentsInstallTests.run(args + ["--apply", token, "--json"], in: scratch)
    #expect(preview.termination == .exit(6))
    #expect(apply.termination == .exit(6))
    #expect(preview.stdout.contains("silta agents " + args[0]))
    #expect(apply.stdout.contains("silta agents " + args[0]))
    #expect(preview.stderr.isEmpty && apply.stderr.isEmpty)
    #expect(preview.stdout.contains(reason) && apply.stdout.contains(reason))
    #expect(try snapshot(scratch) == before)
  }

  @Test func maximumInputCannotProduceUnreadableInstructions() throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(
        String(repeating: "A", count: Self.limit), ".codex/AGENTS.md", in: scratch)
      try Self.refusesWithoutWrites(["install"], in: scratch, reason: "rendered file exceeds")
    }
  }

  @Test(arguments: [0, 1], [".codex/AGENTS.md", ".claude/CLAUDE.md", ".codex/config.toml"])
  func renderedUTF8BoundaryRoundTripsOrRefuses(excess: Int, path: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write("", path, in: scratch)
      #expect(
        try AgentsInstallTests.apply(["install"], in: scratch).termination == .exit(0))
      let overhead = try AgentsInstallTests.read(path, in: scratch).utf8.count
      #expect(
        try AgentsInstallTests.apply(["uninstall"], in: scratch).termination == .exit(0))
      let commentBytes = path.hasSuffix(".toml") ? 2 : 0
      let bytes = Self.limit - overhead + excess - commentBytes
      let padding = String(repeating: "é", count: bytes / 2) + (bytes % 2 == 0 ? "" : "A")
      let original = commentBytes == 0 ? padding : "#" + padding + "\n"
      #expect(original.utf8.count + overhead == Self.limit + excess)
      try AgentsInstallTests.write(original, path, in: scratch)
      if excess == 1 {
        try Self.refusesWithoutWrites(["install"], in: scratch, reason: "rendered file exceeds")
      } else {
        let before = try Self.snapshot(scratch)
        #expect(try AgentsInstallTests.apply(["install"], in: scratch).termination == .exit(0))
        #expect(try AgentsInstallTests.read(path, in: scratch).utf8.count == Self.limit)
        #expect(
          try AgentsInstallTests.data(AgentsInstallTests.run(["install", "--json"], in: scratch))[
            "changes"] as? [[String: String]] == [])
        #expect(try AgentsInstallTests.apply(["uninstall"], in: scratch).termination == .exit(0))
        var expected = before
        if path == ".codex/config.toml", let state = before[path] {
          expected[path] = FileState(
            bytes: Data((original + Self.table + "writable_roots = []\n").utf8),
            metadata: state.metadata)
        }
        #expect(try Self.snapshot(scratch) == expected)
      }
    }
  }

  static func userTable(in scratch: URL) throws -> String {
    let original =
      table + "network_access = false\n\n[private]\napi_key = \"Acme-private-table-key\"\n"
    try AgentsInstallTests.write(original, ".codex/config.toml", in: scratch)
    #expect(
      try AgentsInstallTests.apply(["install", "--codex"], in: scratch).termination == .exit(0))
    let installed = try AgentsInstallTests.read(".codex/config.toml", in: scratch)
    let commented = installed.replacingOccurrences(
      of: table, with: table + " # " + privateNote + "\n")
    try AgentsInstallTests.write(commented, ".codex/config.toml", in: scratch)
    return commented
  }

  @Test func existingUserTableCommentMakesReinstallANoop() throws {
    try withScratchDirectory { scratch in
      let original = try Self.userTable(in: scratch)
      let preview = try AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch)
      let data = try AgentsInstallTests.data(preview)
      let token = try #require(data["token"] as? String)
      let applied = try AgentsInstallTests.run(
        ["install", "--codex", "--apply", token], in: scratch)
      #expect(applied.termination == .exit(0))
      let unchanged = try AgentsInstallTests.read(".codex/config.toml", in: scratch)
      #expect(data["changes"] as? [[String: String]] == [])
      #expect(unchanged == original)
    }
  }

  @Test(arguments: [false, true])
  func userTableUpdateShowsOnlyOwnedChanges(json: Bool) throws {
    try withScratchDirectory { scratch in
      let original = try Self.userTable(in: scratch)
      let root = scratch.appending(path: "silta-home").path
      let moved = ["SILTA_HOME": root + "/relocated"]
      let result = try AgentsInstallTests.run(
        ["install", "--codex"] + (json ? ["--json"] : []), in: scratch, environment: moved)
      #expect(result.termination == .exit(0))
      #expect(!(result.stdout + result.stderr).contains(Self.privateNote))
      #expect(!(result.stdout + result.stderr).contains("Acme-private-table-key"))
      #expect(result.stdout.contains(root + "/relocated"))
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch, environment: moved))
      let changes = try #require(preview["changes"] as? [[String: String]])
      #expect(changes.count == 1 && changes.allSatisfy { $0["diff"]?.isEmpty == false })
      let token = try #require(preview["token"] as? String)
      #expect(
        try AgentsInstallTests.run(
          ["install", "--codex", "--apply", token], in: scratch, environment: moved
        ).termination == .exit(0))
      let updated = try AgentsInstallTests.read(".codex/config.toml", in: scratch)
      let expected = original.replacingOccurrences(
        of: "[\"" + root + "\"]", with: "[\"" + root + "\", \"" + root + "/relocated\"]")
      #expect(Data(updated.utf8) == Data(expected.utf8))
    }
  }

  @Test(arguments: ["install", "uninstall"])
  func identicalValueInAnotherTableIsNotOwned(operation: String) throws {
    try withScratchDirectory { scratch in
      let root = try AgentValueGrantTests.quoted(AgentValueGrantTests.root(scratch))
      let original = "[private_scope]\nwritable_roots = [\(root)]\n"
      try AgentsInstallTests.write(original, ".codex/config.toml", in: scratch)
      #expect(
        try AgentsInstallTests.apply([operation, "--codex"], in: scratch).termination == .exit(0))
      let expected =
        operation == "install" ? original + Self.table + "writable_roots = [\(root)]\n" : original
      #expect(try AgentValueGrantTests.bytes(scratch) == Data(expected.utf8))
    }
  }
}
