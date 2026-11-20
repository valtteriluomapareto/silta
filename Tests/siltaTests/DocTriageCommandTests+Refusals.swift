import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DocTriageCommandTests {
  @Test(arguments: [false, true])
  func staleAndOverlappingAcceptancesHaveReplayableRecovery(stale: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      #expect(try Self.propose(scratch) == "doc:rules@2")
      if stale {
        let changed = try DocEditCommandTests.input(scratch, "Accepted Acme correction.")
        let edited = try DocEditCommandTests.run(["rules", "-F", changed.path], scratch)
        try #require(edited.termination == .exit(0), "\(edited.stdout)")
      } else {
        try AcmeDocAttachments.copyLatestRulesProposal(in: store)
      }
      let args = stale ? ["--accept", "doc:rules@2"] : ["--accept", "doc:rules@2", "doc:rules@3"]
      let before = try Self.truth(store)
      let next = try Self.checkRefusal(args, name: stale ? "stale" : "overlap", in: scratch)
      #expect(try Self.truth(store) == before)
      if stale {
        withKnownIssue("The stale refusal omits the read that supplies the accepted baseline.") {
          #expect(next.contains("silta --ws 'acme' doc show 'doc:rules' --json"))
        }
      }
      try Self.replayRefusal(next, store: store, scratch: scratch)
    }
  }

  private static func checkRefusal(_ args: [String], name: String, in scratch: URL) throws
    -> [String]
  {
    let text = try run(args, scratch)
    #expect(text.termination == .exit(6) && text.stdout.isEmpty)
    Golden.forTests().check(text.stderr, "doc-triage-" + name + ".txt")
    let json = try run(args + ["--json"], scratch)
    #expect(json.termination == .exit(6) && json.stderr.isEmpty)
    Golden.forTests().check(json.stdout, "doc-triage-" + name + ".json")
    let error = try DocEditCommandTests.error(json)
    return try #require(error["next"] as? [String])
  }

  private static func replayRefusal(_ next: [String], store: DatabaseStore, scratch: URL) throws {
    let current = try #require(
      try store.read { try Int.fetchOne($0, sql: "SELECT current_rev FROM doc") })
    let shown = try SiltaBinary.run(["--ws", "acme", "doc", "show", "doc:rules"], in: scratch)
    #expect(shown.termination == .exit(0) && shown.stdout.contains("doc:rules@\(current)"))
    let immutable = try store.read {
      try Row.fetchAll($0, sql: "SELECT * FROM doc_rev ORDER BY id")
    }
    let approvals = try store.read {
      try Row.fetchAll($0, sql: "SELECT * FROM approval ORDER BY id")
    }
    let source = scratch.appending(path: "Acme revised body.md")
    try Data("Rebased Acme guidance for the accepted revision.".utf8).write(to: source)
    let values = [
      "<file>": shellWord(source.path), "<why>": shellWord("Rebase Acme guidance"),
      "<rev>": String(current), "<title>": shellWord("Rules"), "<ref>": shellWord("service:push"),
    ]
    let products = try SiltaBinary.url().deletingLastPathComponent().path
    let env = TaskCommandTests.fixed.merging(["PATH": products + ":/usr/bin:/bin"]) { _, new in new
    }
    for hint in next {
      let command = values.reduce(hint) { command, pair in
        command.replacingOccurrences(of: pair.key, with: pair.value)
      }
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", command], in: scratch, environment: env)
      #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
    }
    try store.read { db in
      let revisions = try Row.fetchAll(db, sql: "SELECT * FROM doc_rev ORDER BY id")
      #expect(revisions.count == immutable.count + 1)
      #expect(Array(revisions.prefix(immutable.count)) == immutable)
      #expect(revisions.last?["state"] as String? == "proposed")
      #expect(revisions.last?["base_rev"] as Int? == current)
      #expect(try Int.fetchOne(db, sql: "SELECT current_rev FROM doc") == current)
      #expect(try Row.fetchAll(db, sql: "SELECT * FROM approval ORDER BY id") == approvals)
    }
  }
}
