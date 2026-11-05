import Foundation
import SiltaTestSupport
import Testing

struct GuideCommandTests {
  static let topics = [
    "when", "start", "recipes", "human", "questions", "blocked", "handoff", "reviews", "refusals",
    "output",
  ]

  @Test func fullGuideMatchesSpec() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["guide"], in: scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      Golden.forTests().check(result.stdout, "guide.txt")
    }
  }

  @Test func topicsComposeFullGuide() throws {
    try withScratchDirectory { scratch in
      let full = try SiltaBinary.run(["guide"], in: scratch)
      var sections: [String] = []
      for topic in Self.topics {
        let result = try SiltaBinary.run(["guide", topic], in: scratch)
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        sections.append(result.stdout)
      }
      #expect(full.stdout == sections.joined(separator: "\n"))
    }
  }

  @Test func referencesMatchSpec() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["help", "refs"], in: scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      Golden.forTests().check(result.stdout, "help-refs.txt")
    }
  }

  @Test func outputModesAndSchema() throws {
    try withScratchDirectory { scratch in
      for args in [["guide"], ["guide", "human"], ["help", "refs"]] {
        let text = try SiltaBinary.run(args, in: scratch)
        let quiet = try SiltaBinary.run(["--quiet"] + args, in: scratch)
        #expect(text == quiet)
        for flags in [["--json"], ["--quiet", "--json"]] {
          let result = try SiltaBinary.run(args + flags, in: scratch)
          if args == ["guide", "human"] || args == ["help", "refs"] {
            Golden.forTests().check(
              result.stdout, args.first == "guide" ? "guide-human.json" : "help-refs.json")
          }
          let envelope = try object(result.stdout)
          #expect(result.termination == .exit(0))
          #expect(result.stderr.isEmpty)
          #expect(envelope["ok"] as? Bool == true)
          #expect(envelope["schema"] as? Int == 1)
          #expect((envelope["warnings"] as? [Any])?.isEmpty == true)
          let data = try #require(envelope["data"] as? [String: Any])
          #expect(data["text"] as? String == text.stdout)
          #expect(Set(data.keys) == (args.first == "guide" ? ["text", "topics"] : ["text"]))
          if args.first == "guide" { #expect(data["topics"] as? [String] == Self.topics) }
        }
      }
      for name in ["guide", "help refs"] {
        let result = try SiltaBinary.run(["schema", name, "--json"], in: scratch)
        let data = try #require(try object(result.stdout)["data"] as? [String: Any])
        let commands = try #require(data["commands"] as? [[String: Any]])
        #expect(commands.count == 1)
        #expect(commands.first?["name"] as? String == "silta " + name)
        let shape = try #require(commands.first?["data"] as? [String: Any])
        let fields = try #require(shape["object"] as? [String: Any])
        #expect(fields["text"] as? String == "string")
        #expect(Set(fields.keys) == (name == "guide" ? ["text", "topics"] : ["text"]))
        if name == "guide" {
          #expect((fields["topics"] as? [String: String])?["array"] == "string")
        }
      }
    }
  }

  @Test func invalidInputsRecover() throws {
    try withScratchDirectory { scratch in
      for (args, code) in [
        (["guide", "nope"], "invalid"), (["guide", "human", "extra"], "usage"),
        (["guide", "--nope"], "usage"), (["help", "refs", "extra"], "usage"),
        (["help", "refs", "--nope"], "usage"),
      ] {
        let result = try SiltaBinary.run(args + ["--json"], in: scratch)
        #expect(result.termination == .exit(1))
        if args == ["guide", "nope"] {
          Golden.forTests().check(result.stdout, "guide-invalid.json")
        }
        #expect(result.stderr.isEmpty)
        let error = try #require(try object(result.stdout)["error"] as? [String: Any])
        #expect(error["code"] as? String == code)
        let next = try #require(error["next"] as? [String])
        #expect(next == [args.first == "guide" ? "silta guide --help" : "silta help refs --help"])
        for command in next {
          let retry = try SiltaBinary.run(
            command.split(separator: " ").dropFirst().map(String.init), in: scratch)
          #expect(retry.termination == .exit(0))
          #expect(retry.stderr.isEmpty)
        }
        let text = try SiltaBinary.run(args, in: scratch)
        #expect(text.termination == .exit(1))
        #expect(text.stdout.isEmpty)
        #expect(text.stderr.contains("[\(code)]"))
        if args == ["guide", "nope"] { Golden.forTests().check(text.stderr, "guide-invalid.txt") }
      }
    }
  }

  @Test func helpRoutesRemainCompatible() throws {
    try withScratchDirectory { scratch in
      for (args, marker) in [
        (["help"], "USAGE: silta"), (["help", "task"], "USAGE: silta task"),
        (["help", "task", "add"], "USAGE: silta task add"),
        (["task", "add", "--help"], "USAGE: silta task add"),
        (["help", "refs", "--help"], "reference"),
        (["guide", "--help"], Self.topics.joined(separator: ", ")),
      ] {
        let result = try SiltaBinary.run(args, in: scratch)
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        #expect(
          result.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(
            marker))
      }
      let baseline = try SiltaBinary.run(["help", "refs"], in: scratch)
      for args in [
        ["--ws", "acme", "help", "refs"], ["help", "--ws=acme", "refs"],
        ["help", "refs", "--ws", "acme"],
      ] {
        #expect(try SiltaBinary.run(args, in: scratch) == baseline)
      }
      let unknown = try SiltaBinary.run(["help", "nope", "--json"], in: scratch)
      #expect(unknown.termination == .exit(0))
      #expect(unknown.stdout.contains("USAGE: silta"))
    }
  }

  @Test func staticReadsPreserveConfiguration() throws {
    try withScratchDirectory { scratch in
      for args in [["guide"], ["help", "refs"]] {
        #expect(try SiltaBinary.run(args, in: scratch).termination == .exit(0))
      }
      let fm = FileManager.default
      let database = scratch.appending(path: "silta-home/silta.db")
      #expect(!fm.fileExists(atPath: database.path))
      for path in ["home/.claude", "home/.codex"] {
        #expect(!fm.fileExists(atPath: scratch.appending(path: path).path))
      }
      for path in ["home/.claude/CLAUDE.md", "home/.codex/config.toml", "home/.codex/AGENTS.md"] {
        let file = scratch.appending(path: path)
        try fm.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: file)
      }
      let corrupt = Data("not a database".utf8)
      try corrupt.write(to: database)
      for ws in ["acme", "another"] {
        for args in [["guide"], ["help", "refs"]] {
          let baseline = try SiltaBinary.run(args, in: scratch)
          #expect(try SiltaBinary.run(["--ws", ws] + args, in: scratch) == baseline)
          #expect(baseline.termination == .exit(0))
          #expect(try Data(contentsOf: database) == corrupt)
        }
      }
      for path in ["home/.claude/CLAUDE.md", "home/.codex/config.toml", "home/.codex/AGENTS.md"] {
        #expect(try Data(contentsOf: scratch.appending(path: path)) == Data("sentinel".utf8))
      }
    }
  }

  @Test func recipesExecute() throws {
    try withScratchDirectory { scratch in
      let fixture = CodeCommandTests()
      let repo = try fixture.setup(scratch)
      let sha = try fixture.git(["rev-parse", "HEAD"], repo, scratch).trimmingCharacters(
        in: .newlines)
      let guide = try SiltaBinary.run(["guide", "recipes"], in: scratch)
      let handoff = try SiltaBinary.run(["guide", "handoff"], in: scratch)
      func blocks(_ text: String) -> [String] {
        text.components(separatedBy: "```sh\n").dropFirst().compactMap {
          $0.components(separatedBy: "```").first
        }
      }
      let recipeBlocks = blocks(guide.stdout)
      let handoffBlocks = blocks(handoff.stdout)
      try #require(recipeBlocks.count == 3)
      try #require(handoffBlocks.count == 1)
      let plan = scratch.appending(path: "acme-plan.md")
      try "# Acme follow-up\n- [ ] Inspect API\n".write(to: plan, atomically: true, encoding: .utf8)
      for script in [
        recipeBlocks[0], recipeBlocks[1], handoffBlocks[0],
        "silta task submit AC-12\n" + recipeBlocks[2],
      ] {
        let concrete = script.replacingOccurrences(of: "AC-12", with: "AC-1")
          .replacingOccurrences(of: "platform-api", with: "console")
          .replacingOccurrences(of: "src/Auth.swift", with: "README.md")
          .replacingOccurrences(of: "'Auth'", with: "'Acme'")
          .replacingOccurrences(of: "/tmp/acme-plan.md", with: shellQuoted(plan.path))
          .replacingOccurrences(of: "<commit-sha>", with: sha)
        let result = try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"), ["-ec", concrete], in: scratch, cwd: repo,
          environment: TaskCommandTests.actor.merging([
            "PATH": try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
          ]) { $1 })
        #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      }
      let shown = try SiltaBinary.run(["task", "show", "AC-1"], in: scratch)
      #expect(shown.stdout.contains("done"))
      #expect(shown.stdout.contains("What was done:"))
      #expect(shown.stdout.contains("[x] Inspect the API"))
    }
  }

  private func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }

  private func object(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }
}
