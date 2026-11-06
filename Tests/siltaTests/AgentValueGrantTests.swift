import Foundation
import SiltaTestSupport
import Testing

struct AgentValueGrantTests {
  static let path = ".codex/config.toml"
  static let table = "[sandbox_workspace_write]\n"
  static let codexTables = """
    [tui]

    [tui.model_availability_nux]
    "acme.model" = 1

    [projects."/acme/platform"]
    trust_level = "trusted"
    # Acme-private-e\u{301}-é  \t
    """ + "\n"

  static func root(_ scratch: URL) -> String { scratch.appending(path: "silta-home").path }
  static func quoted(_ value: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return try #require(String(bytes: encoder.encode(value), encoding: .utf8))
  }
  static func bytes(_ scratch: URL) throws -> Data {
    try Data(contentsOf: scratch.appending(path: "home/" + path))
  }
  static func apply(_ operation: String, in scratch: URL, environment: [String: String] = [:])
    throws
  {
    let args = [operation, "--codex"]
    let data = try AgentsInstallTests.data(
      AgentsInstallTests.run(args + ["--json"], in: scratch, environment: environment))
    let token = try #require(data["token"] as? String)
    #expect(
      try AgentsInstallTests.run(args + ["--apply", token], in: scratch, environment: environment)
        .termination == .exit(0))
  }
  static func noop(_ operation: String, in scratch: URL) throws {
    let data = try AgentsInstallTests.data(
      AgentsInstallTests.run([operation, "--codex", "--json"], in: scratch))
    #expect(data["changes"] as? [[String: String]] == [])
  }

  @Test func codexOwnTablesStayByteExactWithoutConfigMarkers() throws {
    try withScratchDirectory { scratch in
      let original =
        "cli_auth_credentials_store = \"file\"\n" + Self.table + "network_access = false\n"
      try AgentsInstallTests.write(original, Self.path, in: scratch)
      try Self.apply("install", in: scratch)
      let installed = original + "writable_roots = [\(try Self.quoted(Self.root(scratch)))]\n"
      #expect(try Self.bytes(scratch) == Data(installed.utf8))
      try AgentsInstallTests.write(installed + Self.codexTables, Self.path, in: scratch)
      try Self.noop("install", in: scratch)
      try Self.apply("uninstall", in: scratch)
      let expected = original + "writable_roots = []\n" + Self.codexTables
      #expect(try Self.bytes(scratch) == Data(expected.utf8))
      try Self.noop("uninstall", in: scratch)
    }
  }

  @Test(arguments: [0, 1, 2, 3])
  func removesExactlyOneElementAndComma(position: Int) throws {
    try withScratchDirectory { scratch in
      try Self.apply("install", in: scratch)
      let root = try Self.quoted(Self.root(scratch))
      let arrays = [
        "[\(root),  \"/acme/one\",\t\"/acme/two\"]", "[\"/acme/one\",  \(root),\t\"/acme/two\"]",
        "[\"/acme/one\",  \"/acme/two\",\t\(root)]", "[  \(root)\t ]",
      ]
      let removed = [
        "[  \"/acme/one\",\t\"/acme/two\"]", "[\"/acme/one\"  ,\t\"/acme/two\"]",
        "[\"/acme/one\",  \"/acme/two\"\t]", "[  \t ]",
      ]
      let original = Self.table + "writable_roots = " + arrays[position] + "\n" + Self.codexTables
      try AgentsInstallTests.write(original, Self.path, in: scratch)
      try Self.noop("install", in: scratch)
      try Self.apply("uninstall", in: scratch)
      #expect(
        try Self.bytes(scratch)
          == Data(
            (Self.table + "writable_roots = " + removed[position] + "\n" + Self.codexTables).utf8)
      )
      try Self.noop("uninstall", in: scratch)
    }
  }

  @Test(arguments: ["[]", "[  ]", "[ \"/acme/foreign\"  ]"])
  func addsExactlyOncePreservingExistingArray(array: String) throws {
    try withScratchDirectory { scratch in
      let original = Self.table + "writable_roots = " + array + "\n" + Self.codexTables
      try AgentsInstallTests.write(original, Self.path, in: scratch)
      let before = try AgentInstallRoundTwoTests.snapshot(scratch)
      let preview = try AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch)
      #expect(preview.termination == .exit(0))
      #expect(try AgentInstallRoundTwoTests.snapshot(scratch) == before)
      #expect(
        !preview.stdout.contains("/acme/foreign") && !preview.stdout.contains("Acme-private"))
      try Self.apply("install", in: scratch)
      let root = try Self.quoted(Self.root(scratch))
      let expectedArray =
        array == "[ \"/acme/foreign\"  ]"
        ? "[ \"/acme/foreign\", \(root)  ]" : String(array.dropLast()) + root + "]"
      #expect(
        try Self.bytes(scratch)
          == Data(
            (Self.table + "writable_roots = " + expectedArray + "\n" + Self.codexTables).utf8)
      )
      try Self.noop("install", in: scratch)
    }
  }

  @Test(arguments: [
    "", "model = \"acme\"", "[sandbox_workspace_write]",
    "[sandbox_workspace_write]\nnetwork_access = false",
  ])
  func creationRetainsUnprovenEmptyContainers(original: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(original, Self.path, in: scratch)
      try Self.apply("install", in: scratch)
      let root = try Self.quoted(Self.root(scratch))
      let separator = original.isEmpty || original.hasSuffix("\n") ? "" : "\n"
      let expected =
        original.contains(Self.table.trimmingCharacters(in: .newlines))
        ? original + separator + "writable_roots = [\(root)]\n"
        : original + separator + Self.table + "writable_roots = [\(root)]\n"
      #expect(try Self.bytes(scratch) == Data(expected.utf8))
      try Self.apply("uninstall", in: scratch)
      #expect(
        try Self.bytes(scratch) == Data(expected.replacingOccurrences(of: root, with: "").utf8))
    }
  }
}

extension AgentValueGrantTests {
  @Test(arguments: [
    "", table + "network_access = false\n", table + "writable_roots = [\"/acme/foreign\"]\n",
  ])
  func unlocatableHomeRefusesBeforeAnySelectedWrite(original: String) throws {
    withKnownIssue("SI-59/37: generated root is refused by later edits") {
      try withScratchDirectory { scratch in
        if !original.isEmpty { try AgentsInstallTests.write(original, Self.path, in: scratch) }
        let env = ["SILTA_HOME": scratch.appending(path: "acme'''/data").path]
        let before = try AgentInstallRoundTwoTests.snapshot(scratch)
        let preview = try AgentsInstallTests.run(
          ["install", "--json"], in: scratch, environment: env)
        let response = try GuideContractTests.object(preview.stdout)
        let token =
          (response["data"] as? [String: Any])?["token"] as? String
          ?? String(repeating: "0", count: 64)
        #expect(preview.termination == .exit(6))
        #expect(preview.stdout.contains("add this line yourself"))
        #expect(preview.stdout.contains("retain all other entries"))
        #expect(try AgentInstallRoundTwoTests.snapshot(scratch) == before)
        let apply = try AgentsInstallTests.run(
          ["install", "--apply", token, "--json"], in: scratch, environment: env)
        #expect(apply.termination == .exit(6))
        #expect(apply.stdout.contains("add this line yourself"))
        #expect(try AgentInstallRoundTwoTests.snapshot(scratch) == before)
      }
    }
  }

  @Test(arguments: [0, 1, 2])
  func escapedExistingRootUsesDecodedValueOwnership(position: Int) throws {
    try withScratchDirectory { scratch in
      let escaped = try Self.quoted(Self.root(scratch)).replacingOccurrences(
        of: "/", with: #"\u002f"#)
      let arrays = [
        "[ \(escaped), \"/acme/one\", \"/acme/two\" ]",
        "[ \"/acme/one\", \t\(escaped), \"/acme/two\" ]",
        "[ \"/acme/one\", \"/acme/two\", \(escaped) ]",
      ]
      let removed = [
        "[  \"/acme/one\", \"/acme/two\" ]",
        "[ \"/acme/one\" \t, \"/acme/two\" ]",
        "[ \"/acme/one\", \"/acme/two\"  ]",
      ]
      let original = Self.table + "writable_roots = " + arrays[position] + "\n" + Self.codexTables
      try AgentsInstallTests.write(original, Self.path, in: scratch)
      let before = try AgentInstallRoundTwoTests.snapshot(scratch)
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch))
      let changes = try #require(preview["changes"] as? [[String: String]])
      #expect(changes.allSatisfy { $0["path"] != Self.path })
      #expect(try AgentInstallRoundTwoTests.snapshot(scratch) == before)
      try Self.apply("install", in: scratch)
      #expect(try Self.bytes(scratch) == Data(original.utf8))
      try Self.noop("install", in: scratch)
      try Self.apply("uninstall", in: scratch)
      let expected = Self.table + "writable_roots = " + removed[position] + "\n" + Self.codexTables
      #expect(try Self.bytes(scratch) == Data(expected.utf8))
      try Self.noop("uninstall", in: scratch)
    }
  }
}

extension AgentValueGrantTests {
  @Test func manualRecipeNeverReplacesExistingRoots() throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(
        Self.table + "writable_roots = [\n\"/acme/private\"\n]\n", Self.path, in: scratch)
      let result = try AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch)
      #expect(result.termination == .exit(6))
      #expect(!result.stdout.contains("/acme/private"))
      Golden.forTests().check(
        result.stdout.replacingOccurrences(of: Self.root(scratch), with: "<root>"),
        "agents-codex-manual.json")
    }
  }

  @Test func canonicallyEquivalentForeignValueIsNeverOwned() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "data-é")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      let env = ["SILTA_HOME": home.path]
      try Self.apply("install", in: scratch, environment: env)
      let config = try AgentsInstallTests.read(Self.path, in: scratch)
      let line = try #require(
        config.components(separatedBy: "\n").first { $0.hasPrefix("writable_roots = ") })
      let paths = try JSONDecoder().decode(
        [String].self, from: Data(line.dropFirst("writable_roots = ".count).utf8))
      let root = try #require(paths.first)
      let foreign =
        Data(root.utf8) == Data(root.precomposedStringWithCanonicalMapping.utf8)
        ? root.decomposedStringWithCanonicalMapping : root.precomposedStringWithCanonicalMapping
      #expect(Data(root.utf8) != Data(foreign.utf8))
      let foreignToken = try Self.quoted(foreign)
      let rootToken = try Self.quoted(root)
      try AgentsInstallTests.write(
        Self.table + "writable_roots = [\(foreignToken)]\n", Self.path, in: scratch)
      try Self.apply("install", in: scratch, environment: env)
      #expect(
        try Self.bytes(scratch)
          == Data((Self.table + "writable_roots = [\(foreignToken), \(rootToken)]\n").utf8))
      try Self.apply("uninstall", in: scratch, environment: env)
      #expect(
        try Self.bytes(scratch)
          == Data((Self.table + "writable_roots = [\(foreignToken) ]\n").utf8)
      )
    }
  }

  @Test func duplicateMatchingValuesRefuseRatherThanGuess() throws {
    try withScratchDirectory { scratch in
      let token = try Self.quoted(Self.root(scratch))
      try AgentsInstallTests.write(
        Self.table + "writable_roots = [\(token), \(token)]\n", Self.path, in: scratch)
      for operation in ["install", "uninstall"] {
        try AgentInstallRoundTwoTests.refusesWithoutWrites(
          [operation], in: scratch, reason: "retain all other entries")
      }
    }
  }

  @Test(arguments: ["install", "uninstall"])
  func valuePreviewShowsOnlySelectedPath(operation: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(
        Self.table + "writable_roots = [\"/acme/private\"]\n" + Self.codexTables, Self.path,
        in: scratch)
      if operation == "uninstall" { try Self.apply("install", in: scratch) }
      let result = try AgentsInstallTests.run([operation, "--codex", "--json"], in: scratch)
      let changes = try #require(
        try AgentsInstallTests.data(result)["changes"] as? [[String: String]])
      let diff = try #require(changes.first { $0["path"] == Self.path }?["diff"])
      #expect(!result.stdout.contains("/acme/private") && !result.stdout.contains("Acme-private"))
      Golden.forTests().check(
        diff.replacingOccurrences(of: Self.root(scratch), with: "<root>") + "\n",
        "agents-codex-value-\(operation).txt")
    }
  }

  @Test(
    arguments: ["install", "uninstall"],
    [
      "[sandbox_workspace_write]\nwritable_roots = [\n\"/acme\"\n]\n",
      "[sandbox_workspace_write]\nwritable_roots = [\"/acme\",]\n",
      "[sandbox_workspace_write]\nwritable_roots = [1]\n",
      "[sandbox_workspace_write]\nwritable_roots = []\nwritable_roots = []\n",
      "[sandbox_workspace_write]\n[sandbox_workspace_write]\n",
      "[\"sandbox_workspace_write\"]\nwritable_roots = []\n",
      "[\"sand\\u0062ox_workspace_write\"]\nwritable_roots = []\n",
      "sandbox_workspace_write.writable_roots = []\n",
      "sandbox_workspace_write = { writable_roots = [] }\n",
      "note = \"\"\"\n[sandbox_workspace_write]\nwritable_roots = []\n\"\"\"\n",
    ])
  func unsafeShapesRefuseWithManualElementRecipe(operation: String, original: String) throws {
    try withScratchDirectory { scratch in
      try AgentsInstallTests.write(original, Self.path, in: scratch)
      try AgentInstallRoundTwoTests.refusesWithoutWrites(
        [operation], in: scratch,
        reason: operation == "install" ? "add this line yourself" : "remove only")
      let result = try AgentsInstallTests.run([operation, "--codex", "--json"], in: scratch)
      #expect(result.stdout.contains("retain all other entries"))
    }
  }

  @Test func changedHomeAddsAnIndependentGrantAndStaleForeignEditRefuses() throws {
    try withScratchDirectory { scratch in
      let original = Self.table + "writable_roots = [\"/acme/foreign\"]\n" + Self.codexTables
      try AgentsInstallTests.write(original, Self.path, in: scratch)
      try Self.apply("install", in: scratch)
      let before = try Self.bytes(scratch)
      let moved = ["SILTA_HOME": scratch.appending(path: "relocated").path]
      let preview = try AgentsInstallTests.data(
        AgentsInstallTests.run(["install", "--codex", "--json"], in: scratch, environment: moved))
      let token = try #require(preview["token"] as? String)
      try AgentsInstallTests.write(
        try AgentsInstallTests.read(Self.path, in: scratch) + "# foreign edit\n", Self.path,
        in: scratch)
      let snapshot = try AgentInstallRoundTwoTests.snapshot(scratch)
      #expect(
        try AgentsInstallTests.run(
          ["install", "--codex", "--apply", token], in: scratch, environment: moved
        ).termination == .exit(6))
      #expect(try AgentInstallRoundTwoTests.snapshot(scratch) == snapshot)
      try Self.apply("install", in: scratch, environment: moved)
      try Self.apply("uninstall", in: scratch, environment: moved)
      let oldRoot = try Self.quoted(Self.root(scratch))
      let expected =
        try #require(String(bytes: before, encoding: .utf8))
        .replacingOccurrences(of: oldRoot + "]", with: oldRoot + " ]") + "# foreign edit\n"
      #expect(try Self.bytes(scratch) == Data(expected.utf8))
      let after = try AgentsInstallTests.read(Self.path, in: scratch)
      #expect(after.contains(try Self.quoted(Self.root(scratch))))
      #expect(!after.contains(try Self.quoted(scratch.appending(path: "relocated").path)))
    }
  }
}
