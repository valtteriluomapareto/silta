import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposeCommandTests {
  @Test(arguments: [false, true])
  func publicSubmissionHasBodyFreeReceiptAndNoApproval(stdin: Bool) throws {
    withKnownIssue("SI-137: public proposal submission") {
      try withScratchDirectory { scratch in
        let store = try AcmeDocAttachments.make(in: scratch)
        let file = try DocEditCommandTests.input(scratch, "Shared knowledge.")
        let args = [
          "--ws", "acme", "doc", "propose", "rules", "--title", "Rules",
          "--about", "service:push", "-m", "Share the rule.", "--json", "-F",
        ]
        let result =
          try stdin
          ? SiltaBinary.runProcess(
            URL(filePath: "/bin/sh"),
            [
              "-c",
              #""$1" --ws acme doc propose rules --title Rules --about service:push -m Share --json -F - < "$2""#,
              "_", try SiltaBinary.url().path, file.path,
            ],
            in: scratch, environment: TaskCommandTests.fixed)
          : SiltaBinary.run(args + [file.path], in: scratch, environment: TaskCommandTests.fixed)
        #expect(result.termination == .exit(0))
        #expect(result.stderr.isEmpty)
        #expect(
          result.stdout == #"{"data":{"ref":"doc:rules@1"},"ok":true,"schema":1,"warnings":[]}"#
            + "\n")
        if result.termination == .exit(0) {
          try store.read { (db: Database) throws in
            #expect(
              try String.fetchOne(db, sql: "SELECT body_md FROM doc_rev") == "Shared knowledge.")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM link") == 0)
            #expect(
              try Int.fetchOne(db, sql: "SELECT count(*) FROM doc WHERE current_rev IS NULL") == 1)
          }
          let inbox = try SiltaBinary.run(
            ["--ws", "acme", "inbox", "--all", "--json"], in: scratch,
            environment: TaskCommandTests.fixed)
          #expect(inbox.termination == .exit(0) && inbox.stdout.contains("doc_proposal"))
          #expect(!inbox.stdout.contains("doc triage"))
        }
      }
    }
  }

  @Test func availabilityNamesSubmissionAndDefersDecisions() throws {
    withKnownIssue("SI-137: guide and schema expose submission truthfully") {
      try withScratchDirectory { scratch in
        let guide = try SiltaBinary.run(["guide", "docs"], in: scratch)
        #expect(guide.stdout.contains("doc propose"))
        #expect(guide.stdout.contains("cannot decide"))
        #expect(!guide.stdout.contains("cannot submit"))
        let schema = try GuideContractTests.data(
          SiltaBinary.run(["schema", "doc", "--json"], in: scratch))
        let commands = try #require(schema["commands"] as? [[String: Any]])
        #expect(commands.contains { $0["name"] as? String == "silta doc propose" })
      }
    }
  }
}
