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
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix)
            VALUES('acme-unrelated','acme-other','Acme Other','AD')
            """)
      }
      try WorkspaceSelection.use("acme-other", in: store)
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
      try Self.replayRefusal(next, stale: stale, store: store, scratch: scratch)
    }
  }

  @Test func mixedStaleAcceptanceOnlyReproposesTheStaleMember() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      #expect(try Self.propose(scratch) == "doc:rules@2")
      let changed = try DocEditCommandTests.input(scratch, "Accepted Acme correction.")
      let edited = try DocEditCommandTests.run(["rules", "-F", changed.path], scratch)
      try #require(edited.termination == .exit(0), "\(edited.stdout)\(edited.stderr)")
      #expect(try Self.propose(scratch, slug: "fresh") == "doc:fresh@1")
      let before = try Self.truth(store)
      let result = try Self.run(["--accept", "doc:fresh@1", "doc:rules@2", "--json"], scratch)
      #expect(result.termination == .exit(6))
      #expect(try Self.truth(store) == before)
      let error = try DocEditCommandTests.error(result)
      let next = try #require(error["next"] as? [String])
      withKnownIssue("Stale recovery currently asks to re-propose every member.") {
        #expect(
          next == [
            "silta --ws 'acme' doc show 'doc:fresh@1'",
            "silta --ws 'acme' doc show 'doc:rules@2'",
            "silta --ws 'acme' doc show 'doc:rules' --json",
            "silta --ws 'acme' doc propose 'doc:rules'"
              + " -F <file> -m <why> --base <rev> --title <title> --about <ref>",
          ])
      }
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

  private static func replayRefusal(
    _ next: [String], stale: Bool, store: DatabaseStore, scratch: URL
  ) throws {
    let shown = try readBaseline(next, stale: stale, scratch: scratch)
    let current = shown.revision
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
    for hint in next where hint != shown.command {
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

  private static func readBaseline(_ hints: [String], stale: Bool, scratch: URL) throws
    -> (revision: Int, command: String)
  {
    let command =
      if stale {
        try #require(
          hints.first { $0.contains(" doc show 'doc:rules'") && $0.hasSuffix(" --json") })
      } else {
        "silta --ws 'acme' doc show 'doc:rules' --json"
      }
    let shown = try FirstWorkspaceCommandTests.replay(command, in: scratch, cwd: scratch)
    try #require(shown.termination == .exit(0), "\(shown.stdout)\(shown.stderr)")
    let data = try TaskStateCommandTests.data(shown)
    let ref = try #require(data["ref"] as? String)
    let revision = try #require(ref.split(separator: "@").last.flatMap { Int($0) })
    #expect(revision == (stale ? 3 : 1))
    return (revision, command)
  }
}
