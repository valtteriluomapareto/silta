import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposalReferenceCommandTests {
  @Test(arguments: ["text", "json", "quiet"])
  func typedPendingBaseRefusesWithOwnedRecovery(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      let file = try DocEditCommandTests.input(scratch, "Changed knowledge.")
      let args = ["--ws", "acme", "doc", "propose", "rules", "-F", file.path, "-m", "Share"]
      try #require(try SiltaBinary.run(args, in: scratch).termination == .exit(0))
      let before = try store.read {
        try Row.fetchAll($0, sql: "SELECT * FROM seq_counter ORDER BY scope")
      }
      let result = try SiltaBinary.run(
        args + ["--base", "doc:rules@2"] + (mode == "text" ? [] : ["--" + mode]),
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(1))
      Golden.forTests().check(
        mode == "json" ? result.stdout : result.stderr,
        "doc-propose-pending-base" + (mode == "json" ? ".json" : ".txt"))
      #expect(
        try store.read { try Row.fetchAll($0, sql: "SELECT * FROM seq_counter ORDER BY scope") }
          == before)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM doc_rev") } == 2)
    }
  }

  @Test(arguments: ["doc:rules@1", "doc:doc:rules"])
  func invalidTargetWithAbsentStorageDoesNotInitializeIt(target: String) throws {
    try withScratchDirectory { scratch in
      let file = try DocEditCommandTests.input(scratch, "Changed knowledge.")
      let result = try SiltaBinary.run(
        [
          "--ws", "acme", "doc", "propose", target, "--base", "doc:rules@1",
          "-F", file.path, "-m", "Share", "--json",
        ], in: scratch)
      #expect(result.termination == .exit(2))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
    }
  }

  @Test(arguments: ["text", "json", "quiet"], [false, true])
  func printedProposalTargetRecoversInOneRetry(mode: String, metadata: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      let file = try DocEditCommandTests.input(scratch, "Changed knowledge.")
      let result = try SiltaBinary.run(
        ["--ws", "acme", "doc", "propose", "doc:rules@1", "-F", file.path, "-m", "Share"]
          + (metadata ? DocEditCommandTests.creation : [])
          + (mode == "text" ? [] : ["--" + mode]),
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(1))
      if !metadata {
        Golden.forTests().check(
          mode == "json" ? result.stdout : result.stderr,
          "doc-propose-pinned-target" + (mode == "json" ? ".json" : ".txt"))
      }
      let next: String
      if mode == "json" {
        next = try #require((try DocEditCommandTests.error(result)["next"] as? [String])?.first)
      } else {
        next = try #require(
          result.stderr.components(separatedBy: "\n").first { $0.hasPrefix("next: ") }
        )
        .replacingOccurrences(of: "next: ", with: "")
      }
      #expect(!next.contains("doc:rules@1"))
      #expect((result.stdout + result.stderr).contains("Proposals target the doc, not a revision"))
      #expect(metadata || (!next.contains("--title") && !next.contains("--about")))
      let command = next.replacingOccurrences(of: "<file>", with: shellWord(file.path))
        .replacingOccurrences(of: "<why>", with: "Share")
        .replacingOccurrences(of: "<title>", with: "Rules")
        .replacingOccurrences(of: "<ref>", with: "service:push")
      let retried = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        ["-c", "exec " + shellWord(try SiltaBinary.url().path) + command.dropFirst(5)],
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(retried.termination == .exit(0))
      #expect(retried.stdout == "doc:rules@2 proposed\n")
      try store.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev") == 2)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 0)
      }
    }
  }

  @Test(arguments: ["text", "json", "quiet"])
  func printedAcceptedBaseIsUsableAndDocumented(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      let file = try DocEditCommandTests.input(scratch, "Changed knowledge.")
      let result = try SiltaBinary.run(
        [
          "--ws", "acme", "doc", "propose", "rules", "--base", "doc:rules@1", "-F", file.path, "-m",
          "Share",
        ]
          + (mode == "text" ? [] : ["--" + mode]),
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      if mode == "json", result.termination == .exit(0) {
        #expect(try GuideContractTests.data(result)["ref"] as? String == "doc:rules@2")
      } else if mode != "json" {
        #expect(result.stdout == (mode == "quiet" ? "doc:rules@2\n" : "doc:rules@2 proposed\n"))
      }
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT base_rev FROM doc_rev WHERE rev=2") }
          == 1)
      let help = try SiltaBinary.run(["doc", "propose", "--help"], in: scratch)
      #expect(help.stdout.contains("doc:slug@revision"))
      let schema = try GuideContractTests.data(
        SiltaBinary.run(["schema", "doc", "propose", "--json"], in: scratch))
      #expect(String(describing: schema).contains("doc:slug@revision"))
    }
  }
}
