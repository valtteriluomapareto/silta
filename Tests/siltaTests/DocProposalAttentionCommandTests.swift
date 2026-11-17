import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposalAttentionCommandTests {
  @Test func agentTargetingHumanGetsStaleEvidenceAndApprovalInstructions() throws {
    try withScratchDirectory { scratch in
      let (store, (older, latest)) = try fixture(scratch)
      let before = try DocTriageCommandTests.truth(store)
      let result = try DocInboxCommandTests().run(
        ["--ws", "acme", "inbox", "--for", "human:acme", "--json"], scratch)
      let (members, next) = try payload(result)
      #expect(members.first { $0["ref"] as? String == older }?["stale_base"] as? Bool == true)
      #expect(members.first { $0["ref"] as? String == latest }?["stale_base"] as? Bool == false)
      let actions = next.filter { $0.contains("doc triage") }
      #expect(actions.count == 2)
      #expect(actions.allSatisfy { $0.hasPrefix("ask human:") && $0.utf8.count <= 512 })
      #expect(actions.allSatisfy { $0.contains("--approved \"<the human's words>\"") })
      #expect(!actions.contains { $0.contains("--accept " + shellWord(older)) })
      #expect(actions.contains { $0.contains("--reject " + shellWord(older)) })
      let schema = try DocInboxCommandTests().run(["schema", "inbox", "--json"], scratch)
      #expect(schema.stdout.contains("\"stale_base\":\"bool\""))
      #expect(try DocTriageCommandTests.truth(store) == before)
    }
  }

  @Test func printedHumanDecisionsReplayAgainstTheirImmutableRevisions() throws {
    try withScratchDirectory { scratch in
      let (store, (older, latest)) = try fixture(scratch)
      let before = try DocTriageCommandTests.truth(store)
      var result = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/script"),
        [
          "-q", "/dev/null", try SiltaBinary.url().path, "--ws", "acme", "inbox", "--for",
          "human:acme", "--json",
        ], in: scratch,
        environment: DocInboxCommandTests.environment.merging(["SILTA_ACTOR": "human:acme"]) { $1 })
      result.stdout = result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "^D\u{08}\u{08}", with: "")
      let (_, next) = try payload(result)
      let actions = next.filter { $0.contains("doc triage") }
      #expect(actions.count == 3)
      #expect(actions.allSatisfy { !$0.contains("ask human:") && !$0.contains("--approved") })
      #expect(try DocTriageCommandTests.truth(store) == before)
      for (flag, ref) in [("--accept", latest), ("--reject", older)] {
        let command = actions.first { $0.contains("doc triage " + flag + " " + shellWord(ref)) }
        #expect(command != nil)
        if let command {
          let script =
            shellWord(try SiltaBinary.url().path) + String(command.dropFirst(5))
            + " --approved 'Use these Acme decisions' --json"
          let replay = try SiltaBinary.runProcess(
            URL(filePath: "/bin/sh"), ["-c", script], in: scratch,
            environment: DocInboxCommandTests.environment)
          #expect(replay.termination == .exit(0), "\(replay.stdout)\(replay.stderr)")
        }
      }
      if actions.count == 3 {
        try store.read { (db: Database) throws in
          #expect(try Int.fetchOne(db, sql: "SELECT current_rev FROM doc") == 4)
          #expect(
            try String.fetchOne(db, sql: "SELECT state FROM doc_rev WHERE rev=2") == "rejected")
          #expect(
            try String.fetchOne(db, sql: "SELECT state FROM doc_rev WHERE rev=4") == "accepted")
        }
      }
    }
  }

  private func fixture(_ scratch: URL) throws -> (DatabaseStore, (String, String)) {
    let store = try AcmeDocAttachments.make(in: scratch)
    let file = try DocEditCommandTests.input(scratch, "Accepted Acme knowledge.")
    try #require(
      try DocEditCommandTests.run(
        ["rules"] + DocEditCommandTests.creation + ["-F", file.path], scratch
      ).termination == .exit(0))
    let older = try DocTriageCommandTests.propose(scratch)
    let updated = try DocEditCommandTests.input(scratch, "Updated accepted Acme knowledge.")
    try #require(
      try DocEditCommandTests.run(["rules", "-F", updated.path], scratch).termination == .exit(0))
    return (store, (older, try DocTriageCommandTests.propose(scratch)))
  }

  private func payload(_ result: CLIResult) throws -> ([[String: Any]], [String]) {
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
    let data = try GuideContractTests.data(result)
    let items = try #require(data["items"] as? [[String: Any]])
    let item = try #require(items.first)
    let group = try #require(item["doc_proposal"] as? [String: Any])
    return (
      try #require(group["members"] as? [[String: Any]]),
      try #require(item["next"] as? [String])
    )
  }
}
