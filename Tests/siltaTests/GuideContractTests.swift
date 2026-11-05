import Darwin
import Dispatch
import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

struct GuideContractTests {
  @Test func refsUsesOrdinaryGuideRouting() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["guide", "refs"], in: scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("# Reference grammar"))
      let schema = try SiltaBinary.run(["schema", "--json"], in: scratch)
      #expect(!schema.stdout.contains("silta help refs"))
    }
  }

  @Test func jsonIdentifiesSelectedTopic() throws {
    try withScratchDirectory { scratch in
      for topic in [nil, "human", "refs"] as [String?] {
        let result = try SiltaBinary.run(
          ["guide"] + (topic.map { [$0] } ?? []) + ["--json"], in: scratch)
        let data = try Self.data(result)
        if let topic {
          #expect(data["topic"] as? String == topic)
        } else {
          #expect(data["topic"] == nil)
        }
      }
    }
  }

  @Test func topicSentenceMatchesPublishedTopics() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["guide", "--json"], in: scratch)
      let data = try Self.data(result)
      let topics = try #require(data["topics"] as? [String])
      let text = try #require(data["text"] as? String)
      #expect(text.contains("Topics: " + topics.joined(separator: ", ") + "."))
    }
  }

  @Test func unknownTopicListsValidTopics() throws {
    try withScratchDirectory { scratch in
      let full = try Self.data(SiltaBinary.run(["guide", "--json"], in: scratch))
      let topics = try #require(full["topics"] as? [String])
      let result = try SiltaBinary.run(["guide", "nope", "--json"], in: scratch)
      let root = try Self.object(result.stdout)
      let error = try #require(root["error"] as? [String: Any])
      let message = try #require(error["message"] as? String)
      #expect(message.contains("nope"))
      #expect(message.contains(topics.joined(separator: ", ")))
      #expect(message.contains("exact"))
    }
  }

  @Test func refusalRowsMatchSchema() throws {
    try withScratchDirectory { scratch in
      let guide = try SiltaBinary.run(["guide", "refusals"], in: scratch).stdout
      let schema = try SiltaBinary.run(["schema"], in: scratch).stdout
      let rows = try #require(schema.components(separatedBy: "error codes:\n").last)
        .components(separatedBy: "An error's own next_by")[0]
      #expect(guide.contains(rows))
      let structured = try Self.data(SiltaBinary.run(["schema", "--json"], in: scratch))
      let errors = try #require(structured["errors"] as? [[String: Any]])
      for error in errors {
        let code = try #require(error["code"] as? String)
        let exit = try #require(error["exit"] as? Int)
        let actor = try #require(error["next_by"] as? String)
        let advice = try #require(error["agent_should"] as? String)
        #expect(guide.contains("  \(code)  exit \(exit), next by \(actor): \(advice)\n"))
      }
    }
  }

  @Test func referenceTableMatchesSpec() throws {
    try withScratchDirectory { scratch in
      let guide = try SiltaBinary.run(["guide", "refs"], in: scratch)
      let spec = try String(
        contentsOf: ScenarioRunner.repository.appending(path: "docs/spec.md"), encoding: .utf8)
      let section = try #require(spec.components(separatedBy: "### 5.1 Reference grammar").last)
        .components(separatedBy: "## 6.")[0]
      let expected = section.split(separator: "\n").filter { $0.hasPrefix("|") }.map(String.init)
      let actual = guide.stdout.split(separator: "\n").filter { $0.hasPrefix("|") }.map(
        String.init)
      try #require(!actual.isEmpty)
      #expect(actual == expected)
      let prose = section.components(separatedBy: "| Ref |")[0]
      let printed = guide.stdout.components(separatedBy: "| Ref |")[0]
        .replacingOccurrences(of: "# Reference grammar", with: "")
      #expect(
        printed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
          == prose.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
  }

  @Test func staticReadsPreserveWholeHomes() throws {
    try withScratchDirectory { scratch in
      let fm = FileManager.default
      for name in [
        "home/.claude/CLAUDE.md", "home/.codex/config.toml", "home/.config/opencode/config.json",
        "home/.agents/skills/acme/SKILL.md", "silta-home/silta.db", "silta-home/other",
      ] {
        let file = scratch.appending(path: name)
        try fm.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: file)
      }
      let home = try Self.snapshot(scratch.appending(path: "home"))
      let siltaHome = try Self.snapshot(scratch.appending(path: "silta-home"), excludingLog: true)
      for args in [["guide"], ["guide", "refs"], ["--ws", "missing", "guide", "human", "--json"]] {
        #expect(try SiltaBinary.run(args, in: scratch).termination == .exit(0))
        #expect(try Self.snapshot(scratch.appending(path: "home")) == home)
        #expect(
          try Self.snapshot(scratch.appending(path: "silta-home"), excludingLog: true) == siltaHome)
      }
    }
  }

  @Test func staticReadsNeverOpenStore() async throws {
    try await withBlockingTestWork {
      try withScratchDirectory { scratch in
        let directory = scratch.appending(path: "silta-home")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifo = directory.appending(path: "silta.db")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let probe = try Self.observeReader(fifo) {
          try SiltaBinary.runProcess(URL(filePath: "/bin/cat"), [fifo.path], in: scratch)
        }
        #expect(probe.opened)
        for (args, exit) in [
          (["guide"], Int32(0)), (["guide", "refs"], 0),
          (["--ws", "acme", "guide", "human", "--json"], 0),
          (["guide", "refs", "--json"], 0), (["guide", "nope"], 1),
        ] {
          let result = try Self.observeReader(fifo) { try SiltaBinary.run(args, in: scratch) }
          #expect(!result.opened)
          #expect(result.result.termination == .exit(exit))
        }
      }
    }
  }

  @Test func guideSpecMatchesPublishedTopics() throws {
    try withScratchDirectory { scratch in
      let document = try String(
        contentsOf: ScenarioRunner.repository.appending(path: "docs/spec.md"), encoding: .utf8)
      let guide = try #require(document.components(separatedBy: "### `silta guide`").last)
      let paragraph = try #require(guide.components(separatedBy: "Topics are ").last)
        .components(separatedBy: ", also listed")[0]
      let words = paragraph.components(separatedBy: "`")
      let documented = stride(from: 1, to: words.count, by: 2).map { words[$0] }
      let result = try Self.data(SiltaBinary.run(["guide", "--json"], in: scratch))
      #expect(documented == result["topics"] as? [String])
    }
  }

  static func data(_ result: CLIResult) throws -> [String: Any] {
    try #require(try object(result.stdout)["data"] as? [String: Any])
  }

  static func object(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  private static func snapshot(_ root: URL, excludingLog: Bool = false) throws -> [String: Data] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: root.path) else { return [:] }
    var result: [String: Data] = [:]
    for name in try fm.subpathsOfDirectory(atPath: root.path) {
      if excludingLog && (name == "log" || name.hasPrefix("log/")) { continue }
      let url = root.appending(path: name)
      let attributes = try fm.attributesOfItem(atPath: url.path)
      if attributes[.type] as? FileAttributeType == .typeDirectory {
        result[name + "/"] = Data()
      } else {
        result[name] = try Data(contentsOf: url)
      }
    }
    return result
  }

  private static func observeReader(_ fifo: URL, run: @escaping @Sendable () throws -> CLIResult)
    throws
    -> (opened: Bool, result: CLIResult)
  {
    // A nonblocking writer connects only while a reader opens this FIFO. The cat
    // positive control proves the probe observes real opens, including tolerated failures.
    let result = Mutex<Result<CLIResult, any Error>?>(nil)
    DispatchQueue.global().async {
      let value = Result { try run() }
      result.withLock { $0 = value }
    }
    var opened = false
    while result.withLock({ $0 == nil }) {
      let descriptor = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK)
      if descriptor >= 0 {
        opened = true
        close(descriptor)
      }
    }
    return (opened, try #require(result.withLock { $0 }).get())
  }
}
