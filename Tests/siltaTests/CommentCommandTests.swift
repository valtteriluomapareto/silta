import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CommentCommandTests {
  @Test(arguments: [false, true])
  func refusalsKeepExplicitWorkspaceAndClaims(json: Bool) throws {
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
      for (flags, name) in [(["--to", "ext:acme"], "actor"), (["--kind", "handoff"], "handoff")] {
        let result = try SiltaBinary.run(
          ["--ws", "acme", "comment", "AC-1", "-m", "Acme private context"] + flags
            + (json ? ["--json"] : []), in: scratch,
          environment: ["SILTA_ACTOR": "agent:claude:reviewer"])
        #expect(result.termination == .exit(name == "actor" ? 1 : 6))
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
  func coordinatorQuestionAndHandoffAreDiscoverable(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let author = TaskCommandTests.fixed.merging(["USER": "acme"]) { $1 }
      #expect(
        try SiltaBinary.run(
          ["task", "add", "Acme", "--start"], in: scratch, environment: author
        ).termination == .exit(0))
      let flags = json ? ["--json"] : []
      let reviewer = author.merging(["SILTA_ACTOR": "agent:claude:reviewer"]) { $1 }
      let question = try SiltaBinary.run(
        ["comment", "AC-1", "--kind", "question", "-m", "Which API?"] + flags,
        in: scratch, environment: reviewer)
      #expect(question.termination == .exit(0) && question.stderr.isEmpty)
      Golden.forTests().check(question.stdout, "comment-question.\(json ? "json" : "txt")")
      for (kind, body, reply) in [
        ("answer", "Use API v2.", ["--reply-to", "AC-1/1"]),
        ("handoff", "API chosen; continue tests.", []),
      ] {
        let result = try SiltaBinary.run(
          ["comment", "AC-1", "--kind", kind, "-m", body] + reply + flags,
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
