import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposeCommandTests {
  @Test(arguments: [false, true])
  func publicSubmissionHasBodyFreeReceiptAndNoApproval(stdin: Bool) throws {
    do {
      try withScratchDirectory { scratch in
        let store = try AcmeDocAttachments.make(in: scratch)
        let file = try DocEditCommandTests.input(scratch, "Shared knowledge.")
        let args = [
          "--ws", "acme", "doc", "propose", "rules", "--title", "Rules",
          "--about", "service:push", "-m", "Share the rule.", "--json", "-F",
        ]
        let script = #"file=$2; binary=$1; shift 2; exec "$binary" "$@" < "$file""#
        let result =
          try stdin
          ? SiltaBinary.runProcess(
            URL(filePath: "/bin/sh"),
            ["-c", script, "_", try SiltaBinary.url().path, file.path] + args + ["-"],
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
            ["--ws", "acme", "inbox", "--for", "me", "--all", "--json"], in: scratch,
            environment: TaskCommandTests.fixed)
          #expect(inbox.termination == .exit(0) && inbox.stdout.contains("doc_proposal"))
          #expect(!inbox.stdout.contains("doc triage"))
        }
      }
    }
  }

  @Test func availabilityNamesSubmissionAndDefersDecisions() throws {
    do {
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
  @Test(arguments: ["text", "quiet"])
  func completeFileReceipts(mode: String) throws {
    try withScratchDirectory { scratch in
      _ = try AcmeDocAttachments.make(in: scratch)
      let file = try DocEditCommandTests.input(scratch)
      let result = try SiltaBinary.run(
        [
          "--ws", "acme", "doc", "propose", "rules", "--title", "Rules",
          "--about", "service:push", "-m", "Share", "-F", file.path,
        ]
          + (mode == "quiet" ? ["--quiet"] : []),
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      #expect(result.stdout == (mode == "quiet" ? "doc:rules@1\n" : "doc:rules@1 proposed\n"))
    }
  }

  @Test(arguments: ["absent", "nul", "utf8", "large"])
  func inputRefusalsAreBodyFreeAndNeverInitializeAbsentStorage(kind: String) throws {
    try withScratchDirectory { scratch in
      if kind != "absent" { _ = try AcmeDocAttachments.make(in: scratch) }
      let file = scratch.appending(path: "supplied.md")
      let bytes: Data
      switch kind {
      case "nul": bytes = Data([65, 0, 66])
      case "utf8": bytes = Data([255])
      case "large": bytes = Data(repeating: 88, count: 65_537)
      default: bytes = Data("Body".utf8)
      }
      try bytes.write(to: file)
      let result = try SiltaBinary.run(
        [
          "--ws", "acme", "doc", "propose", "rules", "--title", "Rules",
          "--about", "service:push", "-m", "Share", "-F", file.path, "--json",
        ],
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(kind == "absent" ? 2 : 1))
      #expect(!result.stdout.contains(String(repeating: "X", count: 100)))
      if kind == "absent" {
        #expect(
          !FileManager.default.fileExists(
            atPath: scratch.appending(path: "silta-home/silta.db").path))
      }
    }
  }

}
