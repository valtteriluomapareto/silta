import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct HelpCommandTests {
  @Test func everyHelpRouteMatchesGoldenAndRules() throws {
    try withScratchDirectory { scratch in
      let pages = try helpPages(in: scratch)
      let routes = pages.map(\.route)
      let valueOptions = Self.valueOptions(in: pages.map(\.text))
      let schemaAbstracts = try self.schemaAbstracts(in: scratch)
      #expect(routes.count > 40, "help route discovery unexpectedly shrank")
      var byTopLevel: [String: [(route: String, text: String)]] = [:]
      for page in pages {
        #expect(!page.text.isEmpty)
        let abstract = try checkHelpRules(
          page.text, route: page.route, commandValueOptions: valueOptions)
        if let schemaAbstract = schemaAbstracts[page.route] {
          #expect(
            abstract == schemaAbstract, "\(page.route) help and schema summaries differ")
        }
        let words = page.route.split(separator: " ").map(String.init)
        let topLevel = words.count == 1 ? "silta" : words[1]
        byTopLevel[topLevel, default: []].append(page)
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
      let pages = try helpPages(in: scratch)
      let valueOptions = Self.valueOptions(in: pages.map(\.text))
      let result = try SiltaBinary.run(["guide"], in: scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      try checkRuntimeTextRules(
        result.stdout, route: "silta guide", commandValueOptions: valueOptions)
    }
  }

  @Test func existingExamplesParseWithTheRootParser() throws {
    try withScratchDirectory { scratch in
      typealias Example = (route: String, arguments: [String])
      _ = try AcmeWorkspaces.setup(scratch)
      let examples = try helpPages(in: scratch)
        .flatMap { route -> [Example] in
          let labelled = route.text.split(separator: "\n")
            .filter { Self.isExampleLine(String($0)) }
          return try labelled.map { line in
            let arguments = try #require(
              Self.arguments(afterCommandIn: String(line)),
              "\(route.route) has no command: \(line)")
            return (route.route, arguments)
          }
        }
      #expect(!examples.isEmpty, "no existing examples were found")
      for example in examples {
        try checkExampleValues(example.arguments, route: example.route)
        let result = try SiltaBinary.run(example.arguments + ["--json"], in: scratch)
        let error = try Self.errorCode(result.stdout)
        #expect(error != "usage", "\(example.route) example does not parse: \(example.arguments)")
      }
    }
  }

  @Test func unknownCommandWithHelpIsAUsageError() throws {
    try withScratchDirectory { scratch in
      let direct = try SiltaBinary.run(["frobnicate", "--json"], in: scratch)
      let help = try SiltaBinary.run(["frobnicate", "--help", "--json"], in: scratch)
      let helpError = try? Self.errorCode(help.stdout)
      #expect(try Self.errorCode(direct.stdout) == "usage")
      #expect(helpError == "usage")
      #expect(help.stdout == direct.stdout)
    }
  }

  @Test func idRulesCheckProseAndCommandOperands() throws {
    let options: Set<String> = ["--approved", "--prefix"]
    #expect(
      !(try Self.idMatches(
        in: "pass their words as --approved (D39)", pattern: Self.decisionPattern,
        commandValueOptions: options)).isEmpty)
    #expect(
      !(try Self.idMatches(in: "see D39: x", pattern: Self.decisionPattern)).isEmpty)
    #expect(
      !(try Self.idMatches(in: "--json D10-12.", pattern: Self.decisionPattern)).isEmpty)
    #expect(
      try Self.idMatches(
        in: "Example: silta task add --prefix D12", pattern: Self.decisionPattern,
        commandValueOptions: options
      ).isEmpty)
    #expect(try Self.idMatches(in: "app:D12", pattern: Self.decisionPattern).isEmpty)
    #expect(try Self.idMatches(in: "platform-api@M3:path", pattern: Self.milestonePattern).isEmpty)
    #expect(
      !(try Self.idMatches(
        in: "run silta guide refs, then --approved (D39)", pattern: Self.decisionPattern,
        commandValueOptions: options)).isEmpty)
    #expect(!(try Self.idMatches(in: "D10-12", pattern: Self.decisionPattern)).isEmpty)
    #expect(!(try Self.idMatches(in: "M10-12", pattern: Self.milestonePattern)).isEmpty)
  }

  @Test func deterministicRemainsAHiddenWorkingFlag() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["status", "--deterministic", "--json"], in: scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      #expect(try Self.errorCode(result.stdout) == nil)
    }
  }

  private func helpPages(in scratch: URL) throws -> [(route: String, text: String)] {
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
    var pages: [(route: String, text: String)] = []
    for route in routes {
      let words = route.split(separator: " ").map(String.init)
      let arguments = (words.count == 1 ? [] : Array(words.dropFirst())) + ["--help"]
      let result = try SiltaBinary.run(arguments, in: scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      pages.append((route, result.stdout))
    }
    return pages
  }

  @discardableResult
  private func checkHelpRules(
    _ text: String, route: String, commandValueOptions: Set<String>
  ) throws -> String {
    try checkRuntimeTextRules(
      text, route: route, commandValueOptions: commandValueOptions)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let overviewIndex = try #require(lines.firstIndex { $0.hasPrefix("OVERVIEW: ") })
    var abstractLines = [lines[overviewIndex].dropFirst("OVERVIEW: ".count)]
    for line in lines[(overviewIndex + 1)...] {
      guard !line.isEmpty else { break }
      abstractLines.append(line[...])
    }
    let abstract = abstractLines.map { $0.trimmingCharacters(in: .whitespaces) }
      .joined(separator: " ")
    #expect(abstract.count <= 80, "\(route) abstract is too long")
    #expect(abstract.hasSuffix("."), "\(route) abstract must end with a period")
    #expect(
      abstract.filter { $0 == "." }.count == 1, "\(route) abstract must be one sentence")
    #expect(!text.contains("--deterministic"), "\(route) shows the deterministic test knob")
    let globalOptions = try globalOptionsLines(lines)
    #expect(!globalOptions.isEmpty, "\(route) has no global options group")
    for flag in ["--ws", "--approved", "--json", "--quiet", "--verbose"] {
      #expect(
        globalOptions.contains { $0.hasPrefix("  \(flag)") },
        "\(route) is missing \(flag)")
    }
    let usagePrefix =
      route == "silta" ? "USAGE: silta" : "USAGE: silta " + route.dropFirst("silta ".count)
    let usageLines = lines.filter { $0.hasPrefix(usagePrefix) }
    #expect(!usageLines.isEmpty, "\(route) has no accurate usage line")
    let discussion = try discussionLines(text)
    let examples = discussion.filter { Self.isExampleLine($0) }
    let prose = discussion.filter { !Self.isExampleLine($0) }
    #expect(prose.count <= 6, "\(route) discussion has too much prose")
    #expect(examples.count <= 3, "\(route) has more than 3 example lines")
    for example in examples {
      #expect(Self.hasExampleLabel(example), "\(route) has an invalid example label: \(example)")
    }
    if Self.routesRequiringExamples.contains(route) {
      #expect(!examples.isEmpty, "\(route) has no runnable example")
    }
    if route == "silta agents uninstall" {
      #expect(!text.contains("--hook"), "\(route) advertises install-only hooks")
      #expect(!text.contains("--stop-hook"), "\(route) advertises install-only hooks")
    }
    return abstract
  }

  private func checkRuntimeTextRules(
    _ text: String, route: String, commandValueOptions: Set<String>
  ) throws {
    #expect(!text.contains("docs/"), "\(route) names a repository path")
    let milestones = try Self.idMatches(
      in: text, pattern: Self.milestonePattern, commandValueOptions: commandValueOptions)
    let decisions = try Self.idMatches(
      in: text, pattern: Self.decisionPattern, commandValueOptions: commandValueOptions)
    #expect(milestones.isEmpty, "\(route) names a milestone: \(milestones)")
    #expect(decisions.isEmpty, "\(route) names a decision: \(decisions)")
    #expect(
      !text.lowercased().contains("not yet")
        && !text.lowercased().contains("not available")
        && !text.lowercased().contains("waits for"),
      "\(route) contains roadmap text")
  }

  private func schemaAbstracts(in scratch: URL) throws -> [String: String] {
    let result = try SiltaBinary.run(["schema", "--json"], in: scratch)
    let root = try Self.object(result.stdout)
    let data = try #require(root["data"] as? [String: Any])
    let commands = try #require(data["commands"] as? [[String: Any]])
    var abstracts: [String: String] = [:]
    for command in commands {
      abstracts[try #require(command["name"] as? String)] =
        try #require(command["abstract"] as? String)
    }
    return abstracts
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

  private static func errorCode(_ stdout: String) throws -> String? {
    let root = try object(stdout)
    return (root["error"] as? [String: Any])?["code"] as? String
  }

  private static func object(_ json: String) throws -> [String: Any] {
    let root = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    return root
  }
}

extension HelpCommandTests {
  private static let routesRequiringExamples: Set<String> = [
    "silta init", "silta ws edit", "silta agents install", "silta brief",
    "silta task add", "silta task ls", "silta task start", "silta task plan",
    "silta task submit", "silta task done", "silta task block", "silta comment",
    "silta inbox", "silta code grep", "silta code show", "silta export", "silta restore",
  ]

  private static func isExampleLine(_ line: String) -> Bool {
    !line.hasPrefix("USAGE: ") && line.contains(": silta ")
  }

  private static func hasExampleLabel(_ line: String) -> Bool {
    guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
      line[line.index(after: colon)...].hasPrefix(" silta ")
    else { return false }
    let label = line[..<colon]
    return label.first?.isLetter == true
      && label.allSatisfy { $0.isLetter || $0.isNumber || " /'()-".contains($0) }
  }

  fileprivate func checkExampleValues(_ arguments: [String], route: String) throws {
    let allowedValues: [String: Set<String>] = [
      "--kind": Set(CommentDraft.kinds),
      "--status": Set(TaskService.statuses),
      "--rel": Set(TaskService.relations),
    ]
    let arguments = Self.normalizedArguments(arguments)
    for (index, argument) in arguments.enumerated() {
      guard let allowed = allowedValues[argument] else { continue }
      let hasValue = index + 1 < arguments.count
      #expect(hasValue, "\(route) example omits a value for \(argument)")
      guard hasValue else { continue }
      #expect(
        allowed.contains(arguments[index + 1]),
        "\(route) example has an invalid \(argument) value: \(arguments[index + 1])")
    }
  }

  fileprivate static func arguments(afterCommandIn line: String) -> [String]? {
    guard let range = line.range(of: "silta ") else { return nil }
    let words = shellWords(String(line[range.upperBound...]))
    let heredoc = words.firstIndex { $0.hasPrefix("<<") } ?? words.endIndex
    return Array(words[..<heredoc])
  }

  fileprivate static func normalizedArguments(_ arguments: [String]) -> [String] {
    var normalized: [String] = []
    for argument in arguments {
      guard argument.hasPrefix("--"), let separator = argument.firstIndex(of: "=") else {
        normalized.append(argument)
        continue
      }
      normalized.append(String(argument[..<separator]))
      normalized.append(String(argument[argument.index(after: separator)...]))
    }
    return normalized
  }

  fileprivate static func shellWords(_ text: String) -> [String] {
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

  fileprivate static func idMatches(
    in text: String, pattern: String, commandValueOptions: Set<String> = []
  ) throws -> [String] {
    let checked = text.components(separatedBy: .newlines)
      .map { commandCheckedLine($0, commandValueOptions: commandValueOptions) }
      .joined(separator: "\n")
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(checked.startIndex..., in: checked)
    return regex.matches(in: checked, range: range).compactMap { match in
      Range(match.range, in: checked).map { String(checked[$0]) }
    }
  }

  fileprivate static let milestonePattern =
    #"(?<![A-Za-z0-9_@:-])M\d+(?:-\d+)?(?![A-Za-z0-9_-])"#

  fileprivate static let decisionPattern =
    #"(?<![A-Za-z0-9_@:-])D\d+(?:-\d+)?(?![A-Za-z0-9_-])"#

  fileprivate static func commandCheckedLine(
    _ line: String, commandValueOptions: Set<String>
  ) -> String {
    guard line.contains("`") || Self.isCommandLine(line) else { return line }
    var checked = ""
    var rest = line[...]
    while !rest.isEmpty {
      if let opening = rest.firstIndex(of: "`") {
        checked += rest[..<opening] + "`"
        rest = rest[rest.index(after: opening)...]
        guard let closing = rest.firstIndex(of: "`") else {
          checked += rest
          return checked
        }
        checked +=
          removingOptionOperands(
            from: String(rest[..<closing]), commandValueOptions: commandValueOptions) + "`"
        rest = rest[rest.index(after: closing)...]
      } else if let command = rest.range(of: "silta ") {
        checked += rest[..<command.upperBound]
        checked += removingOptionOperands(
          from: String(rest[command.upperBound...]), commandValueOptions: commandValueOptions)
        return checked
      } else {
        checked += rest
        return checked
      }
    }
    return checked
  }

  fileprivate static func isCommandLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("silta ") { return true }
    guard let separator = trimmed.range(of: ": silta ") else { return false }
    let label = trimmed[trimmed.startIndex..<separator.lowerBound]
    return !label.contains("`") && !label.contains("silta")
  }

  fileprivate static func removingOptionOperands(
    from command: String, commandValueOptions: Set<String>
  ) -> String {
    var checked: [String] = []
    var skipsOperand = false
    for word in shellWords(command) {
      if skipsOperand {
        skipsOperand = false
        continue
      }
      if let separator = word.firstIndex(of: "="), word.hasPrefix("-") {
        let option = String(word[..<separator])
        if commandValueOptions.contains(option) {
          checked.append(option)
        } else {
          checked.append(word)
        }
        continue
      }
      if commandValueOptions.contains(word) {
        checked.append(word)
        skipsOperand = true
        continue
      }
      checked.append(word)
    }
    return checked.joined(separator: " ")
  }

  fileprivate static func valueOptions(in pages: [String]) -> Set<String> {
    var options = Set<String>()
    for page in pages {
      for line in page.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard fields.count >= 2, fields[0].hasPrefix("-") else { continue }
        var names = [fields[0].trimmingCharacters(in: CharacterSet(charactersIn: ","))]
        var valueToken = fields[1]
        if fields[1].hasPrefix("-") {
          names.append(fields[1])
          guard fields.count == 3 else { continue }
          valueToken = fields[2]
        }
        guard valueToken.hasPrefix("<") || valueToken.hasPrefix("[<") else { continue }
        options.formUnion(names)
      }
    }
    return options
  }
}
