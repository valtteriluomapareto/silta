import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTriageCommandTests {
  static func propose(_ scratch: URL) throws -> String {
    let file = try DocEditCommandTests.input(scratch, "Shared proposal.")
    let result = try SiltaBinary.run(
      [
        "--ws", "acme", "doc", "propose", "rules", "-F", file.path, "-m", "Share.",
        "--title", "Rules", "--about", "service:push", "--json",
      ],
      in: scratch, environment: TaskCommandTests.fixed)
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
    return try #require(try GuideContractTests.data(result)["ref"] as? String)
  }

  static func run(_ args: [String], _ scratch: URL, approved: Bool = true) throws -> CLIResult {
    try SiltaBinary.run(
      ["--ws", "acme", "doc", "triage"] + args
        + (approved ? ["--approved", "Use the Acme recommendations"] : []),
      in: scratch, environment: TaskCommandTests.fixed)
  }

  static func truth(_ store: DatabaseStore) throws -> [[Row]] {
    try store.read { db in
      try ["doc", "doc_rev", "link", "doc_verification", "approval", "seq_counter", "change_log"]
        .map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid") }
    }
  }

  static func checkSchema(_ result: CLIResult, _ scratch: URL) throws {
    let schema = try GuideContractTests.data(
      SiltaBinary.run(["schema", "doc", "triage", "--json"], in: scratch))
    let commands = try #require(schema["commands"] as? [[String: Any]])
    #expect(
      ShapeCheck.violations(
        of: try GuideContractTests.data(result),
        against: try #require(commands.first?["data"])
      ).isEmpty)
  }

  @Test func rejectionOnlySurfaceMatchesItsContract() throws {
    try withScratchDirectory { scratch in
      for args in [["doc", "triage", "--help"], ["schema", "doc", "triage"]] {
        let result = try SiltaBinary.run(args, in: scratch)
        #expect(result.termination == .exit(0) && result.stdout.contains("--reject"))
        withKnownIssue("Only active rejection grammar is published") {
          #expect(!result.stdout.contains("--accept"))
        }
      }
    }
  }

  @Test func missingWorkspaceKeepsUsableDiscoveryRecovery() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(
        [
          "--ws", "missing", "doc", "triage", "--reject", "doc:rules@1",
          "--approved", "Review Acme rules", "--json",
        ],
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(2))
      let error = try DocEditCommandTests.error(result)
      #expect(error["next"] as? [String] == ["silta ws ls"])
    }
  }

  @Test func agentGateNeverInitializesAnAbsentStore() throws {
    try withScratchDirectory { scratch in
      let denied = try Self.run(["--reject", "doc:rules@1", "--json"], scratch, approved: false)
      #expect(denied.termination == .exit(3))
      #expect(try DocEditCommandTests.error(denied)["code"] as? String == "human_only")
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
    }
  }

  @Test(arguments: ["text", "json", "quiet"])
  func staleRejectionsKeepTheAcceptedProjection(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let file = try DocEditCommandTests.input(scratch)
      try #require(
        try DocEditCommandTests.run(
          ["rules"] + DocEditCommandTests.creation + ["-F", file.path], scratch
        ).termination == .exit(0))
      #expect(try Self.propose(scratch) == "doc:rules@2")
      #expect(try Self.propose(scratch) == "doc:rules@3")
      try #require(
        try DocEditCommandTests.run(
          ["rules", "-F", file.path], scratch
        ).termination == .exit(0))
      try store.write { try $0.database.execute(sql: "DELETE FROM approval") }
      let result = try Self.run(
        ["--reject", "doc:rules@2", "doc:rules@3"]
          + (mode == "text" ? [] : ["--" + mode]), scratch)
      #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      if result.termination == .exit(0) {
        Golden.forTests().check(
          result.stdout, "doc-triage-" + mode + (mode == "json" ? ".json" : ".txt"))
        #expect(!result.stdout.contains("Shared proposal"))
        if mode == "json" { try Self.checkSchema(result, scratch) }
        try store.read { (db: Database) throws in
          #expect(try Int.fetchOne(db, sql: "SELECT current_rev FROM doc") == 4)
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev") == 4)
          #expect(
            try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev WHERE state='rejected'") == 2)
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 1)
          #expect(
            try Int.fetchOne(
              db,
              sql: """
                SELECT count(*) FROM doc_rev WHERE rev IN (2,3)
                  AND actor='agent:codex:acme' AND triaged_by='agent:codex:acme'
                  AND triaged_at IS NOT NULL
                """) == 2)
          #expect(try Int.fetchOne(db, sql: "SELECT count(DISTINCT triaged_at) FROM doc_rev") == 1)
          #expect(
            try String.fetchOne(db, sql: "SELECT body_md FROM doc_rev WHERE rev=2")
              == "Shared proposal.")
        }
      }
    }
  }

  @Test(arguments: [
    ["--reject", "rules"], ["--reject", "doc:rules@01"],
    ["--reject", "doc:rules@1", "doc:rules@1"],
    ["--accept", "doc:rules@1", "--reject", "doc:rules@1"],
    ["--reject", "doc:rules@1,doc:rules@2"], ["--reject", "doc:rules@1", "doc:missing@1"],
  ])
  func invalidMembersNeverPartiallyDecide(args: [String]) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      _ = try Self.propose(scratch)
      let before = try Self.truth(store)
      let result = try Self.run(args + ["--json"], scratch)
      #expect(result.termination == .exit(args.last == "doc:missing@1" ? 2 : 1))
      #expect(
        try DocEditCommandTests.error(result)["code"] as? String
          == (args.last == "doc:missing@1" ? "not_found" : "invalid"))
      #expect(try Self.truth(store) == before)
    }
  }
}
