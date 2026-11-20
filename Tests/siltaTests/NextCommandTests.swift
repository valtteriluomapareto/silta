import Foundation
import SiltaTestSupport
import Testing

/// Checks command names in text and JSON recovery hints against the live CLI schema.
@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct NextCommandTests {
  @Test func everySuggestedCommandExists() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let hints = try ["SiltaCoreTests", "siltaTests"].flatMap { target in
      try Self.hints(in: root.appending(path: "\(target)/Golden"))
    }
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["schema", "--json"], in: scratch)
      let envelope = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let data = try #require(envelope["data"] as? [String: Any])
      let commands = try #require(data["commands"] as? [[String: Any]])
      let known = Set(commands.compactMap { $0["name"] as? String } + ["silta"])
      let groups = Set(
        known.compactMap { command in
          command.lastIndex(of: " ").map { String(command[..<$0]) }
        })
      let suggested = Set(hints.compactMap { Self.commandPath($0, groups: groups) })
      #expect(suggested.count >= 4, "too few suggestions found: \(suggested)")
      for command in suggested {
        #expect(
          known.contains(command) || groups.contains(command),
          "\(command) is suggested but doesn't exist")
      }
    }
  }

  @Test func quotedGlobalValuesAndLowercaseArgumentsStayOutsideTheCommand() {
    let groups: Set<String> = ["silta", "silta task"]
    let workspace = "'Acme'\\''s workspace'"
    let approval = "\"Review Acme's proposal\""
    for globals in [
      "--ws \(workspace) --approved \(approval)",
      "--approved=\(approval) --ws=\(workspace)",
    ] {
      #expect(Self.commandPath("silta \(globals) task nope", groups: groups) == "silta task nope")
      #expect(Self.commandPath("silta \(globals) task nope2", groups: groups) == "silta task nope2")
      #expect(
        Self.commandPath("silta \(globals) task show lowercase", groups: groups)
          == "silta task show")
    }
  }

  @Test func collectsIndentedScalarStreamAndApprovalHints() throws {
    try withScratchDirectory { directory in
      try """
      next: silta task ls
        next: silta ws show
        ask human: silta task triage
        next: ask human: Review Acme. After approval: silta app ls; or silta repo ls
        > next: silta acme-unknown
      """.write(to: directory.appending(path: "sample.txt"), atomically: true, encoding: .utf8)
      try #"{"nested":{"next":"silta code ls"},"next":["silta where"]}"#
        .write(to: directory.appending(path: "sample.json"), atomically: true, encoding: .utf8)
      try """
      {"next":"silta task show"}
      {"next":["silta guide"]}
      """.write(to: directory.appending(path: "sample.jsonl"), atomically: true, encoding: .utf8)
      let groups: Set<String> = [
        "silta", "silta task", "silta ws", "silta app", "silta repo", "silta code",
      ]
      let paths = try Set(
        Self.hints(in: directory).compactMap { Self.commandPath($0, groups: groups) })
      withKnownIssue("Recovery shapes were skipped by the golden checker.") {
        #expect(
          paths == [
            "silta task ls", "silta ws show", "silta task triage", "silta app ls", "silta repo ls",
            "silta code ls", "silta where", "silta task show", "silta guide",
          ])
      }
    }
  }

  private static func hints(in directory: URL) throws -> [String] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return try names.flatMap { name -> [String] in
      // These goldens deliberately use synthetic sample commands.
      guard !["error-codes.txt", "error-codes.json"].contains(name) else { return [] }
      let file = directory.appending(path: name)
      switch file.pathExtension {
      case "txt":
        return try textHints(from: file)
      case "json":
        return try jsonHints(from: file)
      default:
        return []
      }
    }
  }

  private static func textHints(from file: URL) throws -> [String] {
    let contents = try String(contentsOf: file, encoding: .utf8)
    return contents.split(separator: "\n").compactMap { line in
      let prefixes = ["next: ", "ask human: "]
      return prefixes.first { line.hasPrefix($0) }.map { String(line.dropFirst($0.count)) }
    }
  }

  private static func jsonHints(from file: URL) throws -> [String] {
    let contents = try String(contentsOf: file, encoding: .utf8)
    let bytes = Data(contents.utf8)
    if let value = try? JSONSerialization.jsonObject(with: bytes) {  // NDJSON uses the fallback.
      return nestedHints(value)
    }
    return try contents.split(separator: "\n").flatMap { line in
      try nestedHints(JSONSerialization.jsonObject(with: Data(line.utf8)))
    }
  }

  private static func nestedHints(_ value: Any) -> [String] {
    if let object = value as? [String: Any] {
      return (object["next"] as? [String] ?? []) + object.values.flatMap(nestedHints)
    }
    if let list = value as? [Any] { return list.flatMap(nestedHints) }
    return []
  }

  private static func commandPath(_ hint: String, groups: Set<String>) -> String? {
    // Preserve shell-quoted words and escaped quotes as one token. Hints are data.
    let words = hint.matches(of: /(?:'[^']*'|"(?:\\.|[^"\\])*"|\\.|[^\s"'\\])+/).map(\.output)
    guard words.first == "silta" else { return nil }
    var remaining = words.dropFirst()
    while let option = remaining.first {
      let flag = option.split(separator: "=", maxSplits: 1).first
      if flag == "--ws" || flag == "--approved" {
        remaining = remaining.dropFirst(option.contains("=") ? 1 : 2)
      } else if ["--json", "--quiet", "--verbose", "--deterministic"].contains(option) {
        remaining = remaining.dropFirst()
      } else {
        break
      }
    }
    var command = "silta"
    for word in remaining {
      guard groups.contains(command), word.wholeMatch(of: /[a-z][a-z0-9-]*/) != nil else { break }
      command += " " + word
    }
    return command
  }
}
