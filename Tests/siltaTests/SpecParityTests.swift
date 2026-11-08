import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct SpecParityTests {
  @Test func commandsMatchPublishedSchema() throws {
    let section = try cliSection()
    let commands = section.components(separatedBy: "**Commands.**")
    try #require(commands.count == 2)
    let fences = commands[1].components(separatedBy: "```")
    try #require(fences.count >= 3, "§16 must contain a fenced command inventory")
    let lines = fences[1].split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    try #require(!lines.isEmpty)
    var documented: Set<String> = []
    for line in lines {
      // Only these exact suffixes exempt future commands.
      let future = [" [M2]", " [M3]", " [M4]", " [M5]"].first { line.hasSuffix($0) }
      let name = future.map { String(line.dropLast($0.count)) } ?? line
      #expect(
        name.range(of: #"^silta(?: [a-z][a-z0-9-]*)+$"#, options: .regularExpression) != nil,
        "Inventory entries must be complete command paths: \(line)")
      if future == nil {
        #expect(documented.insert(name).inserted, "Duplicate command: \(name)")
      }
    }
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["schema", "--json"], in: scratch)
      try #require(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      let root = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let data = try #require(root["data"] as? [String: Any])
      let entries = try #require(data["commands"] as? [[String: Any]])
      let published = try Set(entries.map { try #require($0["name"] as? String) })
      try #require(!published.isEmpty)
      #expect(published.subtracting(documented).sorted() == [], "Commands missing from §16")
      #expect(documented.subtracting(published).sorted() == [], "Unknown commands in §16")
    }
  }

  @Test func errorCodesAndExitsMatchEnum() throws {
    let section = try cliSection()
    let errors = section.components(separatedBy: "**Exit codes and error codes.**")
    try #require(errors.count == 2)
    let table = errors[1].components(separatedBy: "**Commands.**")
    try #require(table.count == 2)
    let rows = table[0].split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { $0.hasPrefix("|") }
    try #require(rows.count > 2, "§16 must contain the error-code table")
    #expect(rows[0] == "| Exit | Codes | Agent should |")
    #expect(rows[1] == "|---|---|---|")
    var documented: [String: Int32] = [:]
    var successExits: [Int32] = []
    for row in rows.dropFirst(2) {
      let cells = row.split(separator: "|", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      try #require(cells.count == 5, "Malformed error-code row: \(row)")
      let exit = try #require(Int32(cells[1]))
      // Parenthetical explanations are prose, not part of the code list.
      let list = cells[2].components(separatedBy: " (")[0]
      if list == "—" {
        successExits.append(exit)
        continue
      }
      for token in list.components(separatedBy: ", ") {
        try #require(token.hasPrefix("`") && token.hasSuffix("`"), "Invalid code: \(token)")
        let code = String(token.dropFirst().dropLast())
        #expect(documented.updateValue(exit, forKey: code) == nil, "Duplicate code: \(code)")
      }
    }
    #expect(successExits == [0])
    let expected = Dictionary(
      uniqueKeysWithValues: ErrorCode.allCases.map { ($0.rawValue, $0.exitCode) })
    #expect(documented == expected, "§16 codes and exits must match ErrorCode in both directions")
  }

  private func cliSection() throws -> String {
    let document = try String(
      contentsOf: ScenarioRunner.repository.appending(path: "docs/spec.md"), encoding: .utf8)
    let sections = document.components(separatedBy: "## 16. CLI\n")
    try #require(sections.count == 2)
    let end = sections[1].components(separatedBy: "\n## 17.")
    try #require(end.count == 2)
    return end[0]
  }
}
