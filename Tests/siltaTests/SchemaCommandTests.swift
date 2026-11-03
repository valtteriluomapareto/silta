import Foundation
import SiltaTestSupport
import Testing

/// `silta schema` from the outside (spec §20.1). Goldens were written from the spec.
struct SchemaCommandTests {
  private func silta(_ arguments: [String]) throws -> CLIResult {
    try withScratchDirectory { try SiltaBinary.run(arguments, in: $0) }
  }

  private func check(
    _ arguments: [String], exit: Int32 = 0, stdout golden: String? = nil,
    stderr stderrGolden: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let result = try silta(arguments)
    #expect(result.termination == .exit(exit), sourceLocation: sourceLocation)
    if let golden {
      Golden.forTests().check(result.stdout, golden, sourceLocation: sourceLocation)
    } else {
      #expect(result.stdout.isEmpty, sourceLocation: sourceLocation)
    }
    if let stderrGolden {
      Golden.forTests().check(result.stderr, stderrGolden, sourceLocation: sourceLocation)
    } else {
      #expect(result.stderr.isEmpty, sourceLocation: sourceLocation)
    }
  }

  @Test(arguments: [["schema", "--json"], ["--json", "schema"], ["schema", "--quiet", "--json"]])
  func indexInJSON(arguments: [String]) throws {
    try check(arguments, stdout: "schema.json")
  }

  @Test func indexInText() throws {
    try check(["schema"], stdout: "schema.txt")
  }

  @Test(arguments: [["schema", "schema", "--json"], ["schema", "silta", "schema", "--json"]])
  func detailInJSON(arguments: [String]) throws {
    try check(arguments, stdout: "schema-schema.json")
  }

  @Test func detailInText() throws {
    try check(["schema", "schema"], stdout: "schema-schema.txt")
  }

  @Test(arguments: [["schema", "--quiet"], ["--quiet", "schema"]])
  func quietPrintsNothingOnSuccess(arguments: [String]) throws {
    try check(arguments)
  }

  @Test func unknownCommandIsInvalidAndListsTheCommands() throws {
    try check(["schema", "nope"], exit: 1, stderr: "schema-unknown.txt")
    try check(["schema", "nope", "--quiet"], exit: 1, stderr: "schema-unknown.txt")
    try check(["schema", "nope", "--json"], exit: 1, stdout: "schema-unknown.json")
  }

  @Test func unknownFlagOnASubcommandPointsAtItsHelp() throws {
    try check(["schema", "--nope"], exit: 1, stderr: "usage-subcommand-unknown-flag.txt")
    try check(
      ["--json", "schema", "--nope"], exit: 1, stdout: "usage-subcommand-unknown-flag.json")
  }

  @Test(arguments: [["schema", "--help"], ["schema", "--help", "--json"]])
  func helpIsPlainText(arguments: [String]) throws {
    let result = try silta(arguments)
    #expect(result.termination == .exit(0))
    #expect(result.stdout.hasPrefix("OVERVIEW: "))
    #expect(result.stderr.isEmpty)
  }

  // Spec §20.1: every command has a success golden, and each success golden's data
  // matches the shape `schema` publishes for its command. A golden belongs to the
  // command whose words, joined by "-", start its file name: `task-ls-mine.json`
  // belongs to `silta task ls`.
  @Test func everySuccessGoldenMatchesItsCommandsShape() throws {
    let commands = try publishedShapes()
    let golden = Golden.forTests().directory
    var covered: Set<String> = []
    let files = try FileManager.default.contentsOfDirectory(atPath: golden.path)
    for file in files.sorted() where file.hasSuffix(".json") {
      let envelope = try object(Data(contentsOf: golden.appending(path: file)))
      guard envelope["ok"] as? Bool == true else { continue }
      let stem = String(file.dropLast(".json".count))
      let owner = commands.keys.filter { stem == $0 || stem.hasPrefix($0 + "-") }
        .max { $0.count < $1.count }
      let name = try #require(owner, "\(file) names no command")
      covered.insert(name)
      guard let data = envelope["data"] else {
        Issue.record("\(file) has no data")
        continue
      }
      #expect(
        ShapeCheck.violations(of: data, against: try #require(commands[name])) == [], "\(file)")
    }
    #expect(covered == Set(commands.keys), "commands without a success golden")
  }

  // Spec §16: `task ls` returns a summary per task, without bodies.
  @Test func taskListPublishesTheSummaryShape() throws {
    let detail = try object(Data(try silta(["schema", "task", "ls", "--json"]).stdout.utf8))
    let entries = try #require((detail["data"] as? [String: Any])?["commands"] as? [[String: Any]])
    let data = try #require(entries.first?["data"] as? [String: Any])
    let expected = try object(
      Data(
        """
        {"object":{"tasks":{"array":{"object":{
          "app":{"optional":"string"},"claimed_at":{"optional":"string"},
          "claimed_by":{"optional":"string"},"created_at":"string","created_by":"string",
          "external_ref":{"optional":"string"},"follow_up_at":{"optional":"string"},
          "parent":{"optional":"string"},"priority":"int","ref":"string","status":"string",
          "title":"string","updated_at":"string",
          "waiting":{"optional":{"object":{"age_days":"int","dropped":{"array":"string"},
            "on":{"array":"string"},"ready":"bool","why":"string"}}}}}}}}
        """.utf8))
    #expect(NSDictionary(dictionary: data) == NSDictionary(dictionary: expected))
  }

  /// Each command's data shape from `silta schema --json`, keyed by its dash-joined
  /// words without `silta`.
  private func publishedShapes() throws -> [String: Any] {
    let index = try object(Data(try silta(["schema", "--json"]).stdout.utf8))
    let names = try #require((index["data"] as? [String: Any])?["commands"] as? [[String: Any]])
      .compactMap { $0["name"] as? String }
    var shapes: [String: Any] = [:]
    for name in names {
      let words = name.split(separator: " ").dropFirst().map(String.init)
      let detail = try object(Data(try silta(["schema"] + words + ["--json"]).stdout.utf8))
      let entries = try #require(
        (detail["data"] as? [String: Any])?["commands"] as? [[String: Any]])
      let entry = try #require(entries.first { $0["name"] as? String == name })
      guard let shape = entry["data"] else {
        Issue.record("\(name) publishes no data shape")
        continue
      }
      shapes[words.joined(separator: "-")] = shape
    }
    return shapes
  }

  private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
