import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CommentCommandTests {
  @Test func schemaAndStoredThreadsAdvertiseAvailableActionsOnly() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      _ = try SiltaBinary.run(
        ["task", "add", "Acme", "--start"], in: scratch,
        environment: TaskCommandTests.fixed)
      let schema = try SiltaBinary.run(["schema", "comment", "--json"], in: scratch)
      #expect(schema.termination == .exit(0))
      for flag in ["--reply-to", "--to", "--from"] {
        #expect(!schema.stdout.contains("\"" + flag + "\""))
        let invalid = try SiltaBinary.run(
          ["comment", "AC-1", flag, "Acme", "--json"],
          in: scratch, environment: TaskCommandTests.actor)
        #expect(invalid.termination == .exit(1) && invalid.stdout.contains("\"usage\""))
      }
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO comment(id,uid,task_id,seq,kind,body_md,actor,created_at) VALUES
            (1,'q',1,1,'question','Stored question','agent:codex:acme','t');
            INSERT INTO comment(uid,task_id,seq,thread_id,kind,body_md,actor,created_at)
            VALUES('a',1,2,1,'answer','Stored answer','agent:claude:reviewer','t');
            """)
      }
      let shown = try SiltaBinary.run(
        ["task", "show", "AC-1"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(shown.stdout.contains("Stored question") && shown.stdout.contains("Stored answer"))
      #expect(!shown.stdout.contains("--kind answer") && !shown.stdout.contains("--reply-to"))
    }
  }

  @Test(arguments: [false, true], ["codex", "claude"])
  func refusalsKeepExplicitWorkspaceAndClaims(json: Bool, tool: String) throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      #expect(
        try SiltaBinary.run(
          ["task", "add", "Acme", "--start"], in: scratch,
          environment: TaskCommandTests.fixed
        ).termination == .exit(0))
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','ZZ');
            UPDATE meta SET value='other' WHERE key='current_workspace';
            """)
      }
      for (flags, name) in [(["--kind", "question"], "kind"), (["--kind", "handoff"], "handoff")] {
        let result = try SiltaBinary.run(
          ["--ws", "acme", "comment", "AC-1", "-m", "Acme private context"] + flags
            + (json ? ["--json"] : []), in: scratch,
          environment: ["SILTA_ACTOR": "agent:\(tool):reviewer"])
        #expect(result.termination == .exit(name == "kind" ? 1 : 6))
        #expect((json ? result.stderr : result.stdout).isEmpty)
        Golden.forTests().check(
          json ? result.stdout : result.stderr,
          "comment-refused-\(name).\(json ? "json" : "txt")")
      }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM comment") } == 0)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT claimed_by FROM task") }
          == "agent:codex:acme")
    }
  }

  @Test(arguments: [false, true])
  func coordinatorFindingsAndHandoffAreDiscoverable(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let author = TaskCommandTests.fixed.merging(["USER": "acme"]) { $1 }
      #expect(
        try SiltaBinary.run(
          ["task", "add", "Acme", "--start"], in: scratch, environment: author
        ).termination == .exit(0))
      let flags = json ? ["--json"] : []
      let reviewer = author.merging(["SILTA_ACTOR": "agent:claude:reviewer"]) { $1 }
      let finding = try SiltaBinary.run(
        ["comment", "AC-1", "-m", "Review finding."] + flags,
        in: scratch, environment: reviewer)
      #expect(finding.termination == .exit(0) && finding.stderr.isEmpty)
      Golden.forTests().check(finding.stdout, "comment-post.\(json ? "json" : "txt")")
      for (kind, body) in [
        ("comment", "Use API v2."),
        ("handoff", "API chosen; continue tests."),
      ] {
        let result = try SiltaBinary.run(
          ["comment", "AC-1", "--kind", kind, "-m", body] + flags,
          in: scratch, environment: author)
        #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      }
      let shown = try SiltaBinary.run(
        ["task", "show", "AC-1"] + flags, in: scratch, environment: reviewer)
      #expect(shown.termination == .exit(0))
      Golden.forTests().check(shown.stdout, "task-show-discussion.\(json ? "json" : "txt")")
      #expect(try store.read { try String.fetchOne($0, sql: "SELECT claimed_by FROM task") } == nil)
      #expect(
        try SiltaBinary.run(
          ["task", "start", "AC-1"], in: scratch, environment: reviewer
        ).termination == .exit(0))
      let quiet = try SiltaBinary.run(
        ["comment", "AC-1", "--quiet", "-m", "Continuing."], in: scratch, environment: reviewer)
      #expect(quiet.stdout == "AC-1/4\n" && quiet.stderr.isEmpty)
    }
  }
}
