import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocSecretBodyCommandTests {
  @Test(arguments: [false, true])
  func terminalHumanRequiresExplicitSecretBodyOverride(allow: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let before = try DocEditPreparationCommandTests.truth(store)
      let file = try DocEditCommandTests.input(scratch, DocEditCommandTests.secret)
      var result = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/script"),
        ["-q", "/dev/null", try SiltaBinary.url().path, "--ws", "acme", "doc", "edit", "rules"]
          + DocEditCommandTests.creation + ["-F", file.path, "--json"]
          + (allow ? ["--allow-secret"] : []), in: scratch,
        environment: ["SILTA_ACTOR": "human:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
      result.stdout = result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "^D\u{08}\u{08}", with: "")
      #expect(!(result.stdout + result.stderr).contains(DocEditCommandTests.secret))
      if allow {
        #expect(result.stdout.contains("\"ok\":true"))
        try accepted(store, scratch, actor: "human:acme", approvals: 0)
      } else {
        #expect(try DocEditCommandTests.error(result)["code"] as? String == "invalid")
        #expect(try DocEditPreparationCommandTests.truth(store) == before)
      }
    }
  }

  @Test(arguments: [false, true])
  func agentSecretBodyOverrideRequiresHumanWords(approved: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let before = try DocEditPreparationCommandTests.truth(store)
      let file = try DocEditCommandTests.input(scratch, DocEditCommandTests.secret)
      let result = try DocEditCommandTests.run(
        ["rules"] + DocEditCommandTests.creation
          + ["-F", file.path, "--allow-secret"], scratch, approved: approved)
      #expect(!result.stdout.contains(DocEditCommandTests.secret))
      if approved {
        #expect(result.termination == .exit(0))
        try accepted(store, scratch, actor: "agent:codex:acme", approvals: 1)
      } else {
        #expect(result.termination == .exit(3))
        #expect(try DocEditCommandTests.error(result)["code"] as? String == "human_only")
        #expect(try DocEditPreparationCommandTests.truth(store) == before)
      }
    }
  }

  private func accepted(_ store: DatabaseStore, _ scratch: URL, actor: String, approvals: Int)
    throws
  {
    try store.read { (db: Database) throws in
      #expect(
        try String.fetchOne(db, sql: "SELECT body_md FROM doc_rev") == DocEditCommandTests.secret)
      #expect(try String.fetchOne(db, sql: "SELECT actor FROM doc_rev") == actor)
      #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == approvals)
      #expect(
        try String.fetchOne(db, sql: "SELECT actor FROM approval") == (approvals == 0 ? nil : actor)
      )
      #expect(
        try String.fetchOne(db, sql: "SELECT words FROM approval")
          == (approvals == 0 ? nil : "Keep these rules"))
      #expect(
        try String.fetchAll(
          db, sql: "SELECT kind FROM change_log WHERE kind IN ('doc','approval') ORDER BY seq")
          == (approvals == 0 ? ["doc"] : ["doc", "approval"]))
      for command in try String.fetchAll(db, sql: "SELECT command FROM approval") {
        #expect(command.contains("--allow-secret") && command.contains("-F <file>"))
        #expect(!command.contains(DocEditCommandTests.secret))
      }
    }
    let shown = try SiltaBinary.run(
      ["--ws", "acme", "doc", "show", "rules", "--json"],
      in: scratch, environment: TaskCommandTests.fixed)
    #expect(shown.termination == .exit(0) && shown.stdout.contains("[REDACTED:password]"))
    #expect(!shown.stdout.contains(DocEditCommandTests.secret))
    let log = try String(
      contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
    #expect(!log.contains(DocEditCommandTests.secret))
  }
}
