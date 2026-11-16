import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocPendingWorkflowCommandTests {
  @Test(arguments: ["text", "json", "quiet"])
  func duplicateReceiptsNameAnExistingReadableRevision(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try #require(try Self.propose("Shared knowledge.", scratch).termination == .exit(0))
      let before = try Self.counters(store)
      let result = try Self.propose("Shared knowledge.", scratch, mode: mode)
      let after = try Self.counters(store)
      let count = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM doc_rev") }

      #expect(result.termination == .exit(6))
      #expect(before == after && count == 1)
      Golden.forTests().check(
        mode == "json" ? result.stdout : result.stderr,
        "doc-propose-duplicate" + (mode == "json" ? ".json" : ".txt"))

      if result.termination == .exit(6) {
        #expect((mode == "json" ? result.stderr : result.stdout).isEmpty)
        #expect(!(result.stdout + result.stderr).contains("Shared knowledge."))
        let next: String
        if mode == "json" {
          next = try #require((try DocEditCommandTests.error(result)["next"] as? [String])?.first)
        } else {
          next = try #require(
            result.stderr.components(separatedBy: "\n").first {
              $0.hasPrefix("next: ")
            }
          ).replacingOccurrences(of: "next: ", with: "")
        }
        let shown = try Self.follow(next, scratch)
        #expect(shown.termination == .exit(0) && shown.stdout.contains("doc:rules@1 [proposed]"))
      }
    }
  }

  @Test func pendingHintKeepsPinnedPageCoordinates() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      let body = (1...500).map { "Knowledge line \($0)" }.joined(separator: "\n")
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET body_md=CAST(? AS TEXT)", arguments: [Data(body.utf8)])
      }
      let pinned = ["--ws", "acme", "doc", "show", "doc:rules@1"]
      let original = try SiltaBinary.run(pinned, in: scratch)
      for proposal in ["First alternative.", "Second alternative."] {
        try #require(try Self.propose(proposal, scratch).termination == .exit(0))
      }
      let shown = try SiltaBinary.run(["--ws", "acme", "doc", "show", "rules"], in: scratch)
      try #require(shown.termination == .exit(0))
      let lines = shown.stdout.components(separatedBy: "\n")
      #expect(lines[0].contains("2 pending: silta --ws 'acme' doc ls"))
      #expect(lines.count <= 401)
      let footer = try #require(lines.first { $0.contains("lines omitted; next: ") })
      let next = try #require(footer.components(separatedBy: "; next: ").last)
      #expect(next.contains("doc:rules@1") && next.contains("--lines"))
      let continued = try Self.follow(next, scratch)
      #expect(continued.termination == .exit(0))
      let actual = (shown.stdout + continued.stdout).components(separatedBy: "\n").filter {
        $0.hasPrefix("Knowledge line ")
      }
      #expect(actual == (1...500).map { "Knowledge line \($0)" })
      #expect(try SiltaBinary.run(pinned, in: scratch).stdout == original.stdout)
    }
  }

  @Test func guideRequiresDiscoveryBeforeProposing() throws {
    try withScratchDirectory { scratch in
      let guide = try SiltaBinary.run(["guide", "docs"], in: scratch)
      try #require(guide.termination == .exit(0))

      #expect(guide.stdout.contains("doc ls --about <ref>"))
      #expect(guide.stdout.contains("revise an existing doc"))
      #expect(guide.stdout.contains("rediscover"))

    }
  }

  private static func propose(_ body: String, _ scratch: URL, mode: String = "text") throws
    -> CLIResult
  {
    let file = try DocEditCommandTests.input(scratch, body)
    return try SiltaBinary.run(
      ["--ws", "acme", "doc", "propose", "rules"] + DocEditCommandTests.creation
        + ["-F", file.path, "-m", "Share knowledge."]
        + (mode == "text" ? [] : ["--" + mode]),
      in: scratch, environment: TaskCommandTests.fixed)
  }

  private static func counters(_ store: DatabaseStore) throws -> [Row] {
    try store.read { try Row.fetchAll($0, sql: "SELECT * FROM seq_counter ORDER BY scope") }
  }

  private static func follow(_ command: String, _ scratch: URL) throws -> CLIResult {
    try #require(command.hasPrefix("silta "))
    return try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"),
      ["-c", "exec " + shellWord(try SiltaBinary.url().path) + command.dropFirst(5)],
      in: scratch, environment: TaskCommandTests.fixed)
  }
}
