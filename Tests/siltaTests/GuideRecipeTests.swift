import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct GuideRecipeTests {
  @Test func everyPrintedRecipeExecutes() throws {
    try withScratchDirectory { scratch in
      let fixture = try GuideRecipeFixture(scratch)
      let guide = try fixture.run(["guide"]).stdout
      let blocks = Self.blocks(guide)
      try #require(blocks.count == 7)
      #expect(blocks[2].contains("silta task submit AC-12"))
      for index in [0, 1, 3, 4, 5, 6, 2] {
        if index == 4 {
          _ = try fixture.run([
            "task", "add", "Acme external dependency", "--start", "--app", "none",
          ])
        }
        let target = index == 4 ? "AC-3" : "AC-1"
        if index == 1 {
          let dry = try #require(
            blocks[index].components(separatedBy: "\n").first {
              $0.contains("--dry-run")
            })
          let parts = blocks[index].components(separatedBy: dry)
          try #require(parts.count == 2)
          try fixture.shell(parts[0], task: target)
          let before = try fixture.taskCount()
          try fixture.shell(dry, task: target)
          #expect(try fixture.taskCount() == before)
          try fixture.shell(parts[1], task: target)
        } else {
          try fixture.shell(blocks[index], task: target)
        }
        if index == 5 {
          let task = try GuideContractTests.data(fixture.run(["task", "show", target, "--json"]))
          #expect(task["claimed_by"] == nil)
          #expect(task["status"] as? String == "doing")
          let comments = try #require(task["comments"] as? [[String: Any]])
          #expect(comments.contains { $0["kind"] as? String == "handoff" })
        }
      }
      let task = try GuideContractTests.data(fixture.run(["task", "show", "AC-1", "--json"]))
      #expect(task["status"] as? String == "done")
      #expect((task["result"] as? String)?.contains("What was done:") == true)
      let imported = try GuideContractTests.data(fixture.run(["task", "show", "AC-2", "--json"]))
      #expect(imported["status"] as? String == "proposed")
    }
  }

  @Test func inlineCommandsParse() throws {
    try withScratchDirectory { scratch in
      let fixture = try GuideRecipeFixture(scratch)
      let guide = try fixture.run(["guide"]).stdout
      let spans = guide.components(separatedBy: "`")
      for index in stride(from: 1, to: spans.count, by: 2) where spans[index].hasPrefix("silta ") {
        var command = spans[index].replacingOccurrences(of: "<topic>", with: "human")
          .replacingOccurrences(of: "<cmd>", with: "guide")
          .replacingOccurrences(of: "<[^>]+>", with: "example", options: .regularExpression)
        command = command.replacingOccurrences(of: " --help", with: "")
        // This inline command names the family; supply its required title.
        if command == "silta task add" { command += " 'Acme proposal' --app none" }
        let result = try fixture.execute(command + " --json", task: "AC-1")
        let root = try GuideContractTests.object(result.stdout)
        let error = root["error"] as? [String: Any]
        #expect(error?["code"] as? String != "usage", "\(command): \(result.stdout)")
      }
    }
  }

  static func blocks(_ text: String) -> [String] {
    text.components(separatedBy: "```sh\n").dropFirst().compactMap {
      $0.components(separatedBy: "```").first
    }
  }
}

private struct GuideRecipeFixture {
  let scratch: URL
  let repo: URL
  let sha: String
  let plan: URL

  init(_ scratch: URL) throws {
    self.scratch = scratch
    let fixture = CodeCommandTests()
    repo = try fixture.setup(scratch)
    sha = try fixture.git(["rev-parse", "HEAD"], repo, scratch).trimmingCharacters(in: .newlines)
    plan = scratch.appending(path: "acme-plan.md")
    try "# Acme follow-up\n- [ ] Inspect API\n".write(to: plan, atomically: true, encoding: .utf8)
  }

  func run(_ arguments: [String]) throws -> CLIResult {
    try SiltaBinary.run(arguments, in: scratch, cwd: repo, environment: TaskCommandTests.actor)
  }

  func shell(_ text: String, task: String) throws {
    let result = try execute(text, task: task)
    #expect(result.termination == .exit(0), "\(text)\n\(result.stdout)\(result.stderr)")
    #expect(!result.stderr.contains("handoff_unclaimed"))
  }

  func execute(_ text: String, task: String) throws -> CLIResult {
    let script = text.replacingOccurrences(of: "AC-12", with: task)
      .replacingOccurrences(of: "platform-api", with: "console")
      .replacingOccurrences(of: "src/Auth.swift", with: "README.md")
      .replacingOccurrences(of: "'Auth'", with: "'Acme'")
      .replacingOccurrences(of: "/tmp/acme-plan.md", with: shellWord(plan.path))
      .replacingOccurrences(of: "<commit-sha>", with: sha)
    return try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"), ["-ec", script], in: scratch, cwd: repo,
      environment: TaskCommandTests.actor.merging([
        "PATH": try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
      ]) { $1 })
  }

  func taskCount() throws -> Int {
    let store = DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 0)), jitter: { 0 })
    return try store.read { try #require(try Int.fetchOne($0, sql: "SELECT count(*) FROM task")) }
  }
}
