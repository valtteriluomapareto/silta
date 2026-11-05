import Foundation
import SiltaTestSupport
import Testing

struct GuideCommandTests {
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
      let data = try GuideReviewTests.data(SiltaBinary.run(["guide", "--json"], in: scratch))
      let topics = try #require(data["topics"] as? [String])
      var sections: [String] = []
      for topic in topics {
        let result = try SiltaBinary.run(["guide", topic], in: scratch)
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        sections.append(result.stdout)
      }
      #expect(full.stdout == sections.joined(separator: "\n"))
    }
  }

  @Test func outputModesAndSchema() throws {
    try withScratchDirectory { scratch in
      for args in [["guide"], ["guide", "human"], ["guide", "refs"]] {
        let text = try SiltaBinary.run(args, in: scratch)
        #expect(try SiltaBinary.run(["--quiet"] + args, in: scratch) == text)
        for flags in [["--json"], ["--quiet", "--json"]] {
          let result = try SiltaBinary.run(args + flags, in: scratch)
          #expect(result.termination == .exit(0))
          #expect(result.stderr.isEmpty)
          if let topic = args.dropFirst().first {
            Golden.forTests().check(result.stdout, "guide-\(topic).json")
          }
          let root = try GuideReviewTests.object(result.stdout)
          #expect(root["ok"] as? Bool == true)
          #expect(root["schema"] as? Int == 1)
          #expect((root["warnings"] as? [Any])?.isEmpty == true)
          let data = try GuideReviewTests.data(result)
          #expect(data["text"] as? String == text.stdout)
          #expect(Set(data.keys) == ["text", "topics", "topic"])
        }
      }
      let result = try SiltaBinary.run(["schema", "guide", "--json"], in: scratch)
      let commands = try #require(try GuideReviewTests.data(result)["commands"] as? [[String: Any]])
      #expect(commands.count == 1)
      let shape = try #require(commands.first?["data"] as? [String: Any])
      let fields = try #require(shape["object"] as? [String: Any])
      #expect(Set(fields.keys) == ["text", "topics", "topic"])
      #expect(fields["text"] as? String == "string")
      #expect((fields["topics"] as? [String: String])?["array"] == "string")
      #expect((fields["topic"] as? [String: String])?["nullable"] == "string")
    }
  }

  @Test func invalidInputsRecover() throws {
    try withScratchDirectory { scratch in
      for (args, code) in [
        (["guide", "nope"], "invalid"), (["guide", "human", "extra"], "usage"),
        (["guide", "--nope"], "usage"), (["guide", "refs", "extra"], "usage"),
        (["guide", "refs", "--nope"], "usage"),
      ] {
        let result = try SiltaBinary.run(args + ["--json"], in: scratch)
        #expect(result.termination == .exit(1))
        #expect(result.stderr.isEmpty)
        if args == ["guide", "nope"] {
          Golden.forTests().check(result.stdout, "guide-invalid.json")
        }
        let root = try GuideReviewTests.object(result.stdout)
        let error = try #require(root["error"] as? [String: Any])
        #expect(error["code"] as? String == code)
        let next = try #require(error["next"] as? [String])
        #expect(next == ["silta guide --help"])
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
        (["guide", "--help"], "Topic names are exact (case-sensitive)."),
      ] {
        let result = try SiltaBinary.run(args, in: scratch)
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        #expect(
          result.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(
            marker))
      }
    }
  }

  @Test func handoffStopsWithoutReclaiming() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      _ = try SiltaBinary.run(
        ["task", "add", "Acme", "--start"], in: scratch, environment: TaskCommandTests.actor)
      let guide = try SiltaBinary.run(["guide", "handoff"], in: scratch)
      let script = try #require(GuideRecipeTests.blocks(guide.stdout).first)
        .replacingOccurrences(of: "AC-12", with: "AC-1")
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-ec", script], in: scratch,
        environment: TaskCommandTests.actor.merging([
          "PATH": try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
        ]) { $1 })
      #expect(result.termination == .exit(0))
      let shown = try SiltaBinary.run(["task", "show", "AC-1", "--json"], in: scratch)
      let task = try GuideReviewTests.data(shown)
      #expect(task["claimed_by"] == nil)
      #expect(task["status"] as? String == "doing")
      let comments = try #require(task["comments"] as? [[String: Any]])
      #expect(comments.contains { $0["kind"] as? String == "handoff" })
    }
  }
}
