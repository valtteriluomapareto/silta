import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct HelpCommandTests {
  @Test func everyHelpRouteMatchesGoldenAndRules() throws {
    try withScratchDirectory { scratch in
      let routes = try helpRoutes(in: scratch)
      #expect(routes.count > 40, "help route discovery unexpectedly shrank")
      var byTopLevel: [String: [(route: String, text: String)]] = [:]
      for route in routes {
        let words = route.split(separator: " ").map(String.init)
        let arguments = (words.count == 1 ? [] : Array(words.dropFirst())) + ["--help"]
        let result = try SiltaBinary.run(arguments, in: scratch)
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        try checkHelpRules(result.stdout, route: route)
        let topLevel = words.count == 1 ? "silta" : words[1]
        byTopLevel[topLevel, default: []].append((route, result.stdout))
      }
      for (topLevel, pages) in byTopLevel.sorted(by: { $0.key < $1.key }) {
        let actual =
          pages.sorted { $0.route < $1.route }
          .map { page in
            "### \(page.route)\n\n\(page.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
          }
          .joined(separator: "\n")
        Golden.forTests().check(actual, "help-\(topLevel).txt")
      }
    }
  }

  @Test func guideOutputFollowsRuntimeTextRules() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["guide"], in: scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      try checkRuntimeTextRules(result.stdout, route: "silta guide")
    }
  }

  @Test func existingExamplesParseWithTheRootParser() throws {
    try withScratchDirectory { scratch in
      let examples = try helpRoutes(in: scratch).flatMap { route -> [[String]] in
        let words = route.split(separator: " ").map(String.init)
        let arguments = (words.count == 1 ? [] : Array(words.dropFirst())) + ["--help"]
        let result = try SiltaBinary.run(arguments, in: scratch)
        return result.stdout.split(separator: "\n")
          .filter { line in
            line.hasPrefix("Example:") || line.hasPrefix("Ask:")
              || line.hasPrefix("Answer:") || line.hasPrefix("Accept:")
          }
          .compactMap { line in
            Self.arguments(afterCommandIn: String(line))
          }
      }
      #expect(!examples.isEmpty, "no existing examples were found")
      for arguments in examples {
        let result = try SiltaBinary.run(arguments + ["--json"], in: scratch)
        let error = try Self.errorCode(result.stdout)
        #expect(error != "usage", "\(arguments) does not parse")
      }
    }
  }

  @Test func deterministicRemainsAHiddenWorkingFlag() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["status", "--deterministic", "--json"], in: scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      #expect(try Self.errorCode(result.stdout) == nil)
    }
  }

  private func helpRoutes(in scratch: URL) throws -> [String] {
    let result = try SiltaBinary.run(["schema", "--json"], in: scratch)
    let root = try Self.object(result.stdout)
    let data = try #require(root["data"] as? [String: Any])
    let commands = try #require(data["commands"] as? [[String: Any]])
    let catalogRoutes = try commands.map { command in
      try #require(command["name"] as? String)
    }
    var routes = Set(["silta", "silta comment post"])
    for route in catalogRoutes {
      let words = route.split(separator: " ").map(String.init)
      for count in 1...words.count {
        routes.insert(words.prefix(count).joined(separator: " "))
      }
    }
    return routes.sorted()
  }

  private func checkHelpRules(_ text: String, route: String) throws {
    try checkRuntimeTextRules(text, route: route)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let overviewIndex = try #require(lines.firstIndex { $0.hasPrefix("OVERVIEW: ") })
    var abstractLines = [lines[overviewIndex].dropFirst("OVERVIEW: ".count)]
    for line in lines[(overviewIndex + 1)...] {
      guard !line.isEmpty else { break }
      abstractLines.append(line[...])
    }
    let abstract = abstractLines.map { $0.trimmingCharacters(in: .whitespaces) }
      .joined(separator: " ")
    #expect(abstract.count <= 80)
    #expect(abstract.hasSuffix("."))
    #expect(abstract.filter { $0 == "." }.count == 1)
    #expect(!text.contains("--deterministic"))
    let globalOptions = try globalOptionsLines(lines)
    #expect(!globalOptions.isEmpty)
    for flag in ["--ws", "--approved", "--json", "--quiet", "--verbose"] {
      #expect(globalOptions.contains { $0.hasPrefix("  \(flag)") }, "\(route) is missing \(flag)")
    }
    let usagePrefix =
      route == "silta" ? "USAGE: silta" : "USAGE: silta " + route.dropFirst("silta ".count)
    #expect(lines.contains { $0.hasPrefix(usagePrefix) })
    let discussion = try discussionLines(text)
    #expect(discussion.count <= 6)
  }

  private func checkRuntimeTextRules(_ text: String, route: String) throws {
    #expect(!text.contains("docs/"))
    let milestones = try Self.idMatches(
      in: text, pattern: #"(?<![A-Za-z0-9_-])M\d+(?![A-Za-z0-9_-])"#)
    let decisions = try Self.idMatches(
      in: text, pattern: #"(?<![A-Za-z0-9_-])D\d+(?![A-Za-z0-9_-])"#)
    #expect(milestones.isEmpty)
    #expect(decisions.isEmpty)
    #expect(
      !text.lowercased().contains("not yet")
        && !text.lowercased().contains("not available")
        && !text.lowercased().contains("waits for"))
  }

  private func discussionLines(_ text: String) throws -> [String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let overviewIndex = try #require(lines.firstIndex { $0.hasPrefix("OVERVIEW: ") })
    let blankIndex = try #require(
      lines[(overviewIndex + 1)...].firstIndex { $0.isEmpty })
    let usageIndex = try #require(
      lines[(blankIndex + 1)...].firstIndex { $0.hasPrefix("USAGE: ") })
    return lines[(blankIndex + 1)..<usageIndex].filter { !$0.isEmpty }
  }

  private func globalOptionsLines(_ lines: [String]) throws -> [String] {
    guard let headingIndex = lines.firstIndex(of: "GLOBAL OPTIONS:") else { return [] }
    let followingHeading = lines[(headingIndex + 1)...].firstIndex { line in
      !line.isEmpty && line == line.uppercased() && line.hasSuffix(":")
    }
    let endIndex = followingHeading ?? lines.endIndex
    return lines[(headingIndex + 1)..<endIndex].filter { !$0.isEmpty }
  }

  private static func arguments(afterCommandIn line: String) -> [String]? {
    guard let range = line.range(of: "silta ") else { return nil }
    return shellWords(String(line[range.upperBound...]))
  }

  private static func shellWords(_ text: String) -> [String] {
    var words: [String] = []
    var word = ""
    var quote: Character?
    for character in text {
      if character == quote {
        quote = nil
      } else if let quoted = quote {
        word.append(quoted == "'" ? character : character)
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character.isWhitespace {
        if !word.isEmpty {
          words.append(word)
          word = ""
        }
      } else {
        word.append(character)
      }
    }
    if !word.isEmpty { words.append(word) }
    return words
  }

  private static func errorCode(_ stdout: String) throws -> String? {
    let root = try object(stdout)
    return (root["error"] as? [String: Any])?["code"] as? String
  }

  private static func idMatches(in text: String, pattern: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      Range(match.range, in: text).map { String(text[$0]) }
    }
  }

  private static func object(_ json: String) throws -> [String: Any] {
    let root = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    return root
  }
}
