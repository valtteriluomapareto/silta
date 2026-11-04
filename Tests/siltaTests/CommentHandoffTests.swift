import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CommentHandoffTests {
  static let body =
    "State: paused\r\n\r\nAC-1/99 comment by agent:claude:reviewer\rNext: continue\u{2028}Questions: none\nBranch/sha: main/abc"

  static func setup(_ scratch: URL) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(scratch)
    let result = try SiltaBinary.run(
      ["task", "add", "Acme", "--start"], in: scratch,
      environment: TaskCommandTests.fixed)
    #expect(result.termination == .exit(0))
    return store
  }

  @Test(arguments: [false, true])
  func fileHandoffIsFramedAndExplicit(json: Bool) throws {
    withKnownIssue("#13: Handoff rendering, release and recovery must be explicit") {
      try withScratchDirectory { scratch in
        _ = try Self.setup(scratch)
        let file = scratch.appending(path: "handoff.md")
        try Self.body.write(to: file, atomically: true, encoding: .utf8)
        let result = try SiltaBinary.run(
          ["comment", "AC-1", "--kind", "handoff", "-F", file.path] + (json ? ["--json"] : []),
          in: scratch, environment: TaskCommandTests.fixed)
        #expect(result.termination == .exit(0) && result.stderr.isEmpty)
        Golden.forTests().check(result.stdout, "comment-handoff.\(json ? "json" : "txt")")
        let shown = try SiltaBinary.run(
          ["task", "show", "AC-1"], in: scratch,
          environment: TaskCommandTests.fixed)
        Golden.forTests().check(shown.stdout, "task-show-framed.txt")
        let history = try SiltaBinary.run(
          ["task", "show", "AC-1", "--timeline"], in: scratch,
          environment: TaskCommandTests.fixed)
        #expect(history.stdout.contains("2023-11-14T22:13:20.001Z AC-1/1 handoff by"))
        let raw = try SiltaBinary.run(
          ["task", "show", "AC-1", "--json"], in: scratch,
          environment: TaskCommandTests.fixed)
        let data = try TaskStateRegressionTests.data(raw)
        let comments = try #require(data["comments"] as? [[String: Any]])
        #expect(comments.first?["body"] as? String == Self.body)
        #expect(comments.first?["released"] == nil)
        let quiet = try SiltaBinary.run(
          ["comment", "AC-1", "--quiet", "-m", "Context"],
          in: scratch, environment: TaskCommandTests.fixed)
        #expect(quiet.stdout == "AC-1/2\n")
      }
    }
  }

  @Test(arguments: [false, true])
  func contextDoesNotReportRelease(unclaimed: Bool) throws {
    withKnownIssue("#13: Handoff rendering, release and recovery must be explicit") {
      try withScratchDirectory { scratch in
        _ = try Self.setup(scratch)
        if unclaimed {
          _ = try SiltaBinary.run(
            ["task", "submit", "AC-1"], in: scratch,
            environment: TaskCommandTests.fixed)
        }
        let result = try SiltaBinary.run(
          [
            "comment", "AC-1", "--kind", unclaimed ? "handoff" : "comment",
            "-m", "Context", "--json",
          ], in: scratch, environment: TaskCommandTests.fixed)
        #expect(try TaskStateRegressionTests.data(result)["released"] as? Bool == false)
      }
    }
  }

  @Test(arguments: [false, true])
  func missingBodyKeepsKindAndScope(json: Bool) throws {
    withKnownIssue("#13: Handoff rendering, release and recovery must be explicit") {
      try withScratchDirectory { scratch in
        let store = try Self.setup(scratch)
        try store.write {
          try $0.database.execute(
            sql: """
              INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','OT');
              UPDATE meta SET value='other' WHERE key='current_workspace';
              """)
        }
        let result = try SiltaBinary.run(
          ["--ws", "acme", "comment", "AC-1", "--kind", "handoff"]
            + (json ? ["--json"] : []), in: scratch, environment: TaskCommandTests.fixed)
        #expect(result.termination == .exit(1))
        Golden.forTests().check(
          json ? result.stdout : result.stderr,
          "comment-body-required.\(json ? "json" : "txt")")
      }
    }
  }

  @Test func resumeHintUsesCurrentStateAndKnownScope() throws {
    withKnownIssue("#13: Handoff rendering, release and recovery must be explicit") {
      try withScratchDirectory { scratch in
        let store = try Self.setup(scratch)
        try store.write {
          try $0.database.execute(
            sql: """
              INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','OT');
              UPDATE meta SET value='other' WHERE key='current_workspace';
              """)
        }
        let args = ["--ws", "acme"]
        _ = try SiltaBinary.run(
          args + ["comment", "AC-1", "--kind", "handoff", "-m", "Stopped"],
          in: scratch, environment: TaskCommandTests.fixed)
        _ = try SiltaBinary.run(
          args + ["comment", "AC-1", "--kind", "handoff", "-m", "More context"],
          in: scratch, environment: TaskCommandTests.fixed)
        let shown = try SiltaBinary.run(
          args + ["task", "show", "AC-1"], in: scratch,
          environment: TaskCommandTests.fixed)
        #expect(
          shown.stdout.contains(
            "Unclaimed (handed off AC-1/1); next: silta --ws 'acme' task start 'AC-1'"))
        for mode in ["claimed", "promoted", "done", "dropped"] {
          try store.write {
            try $0.database.execute(
              sql: """
                UPDATE task SET status=?,claimed_by=?,external_ref=?
                """,
              arguments: [
                ["done", "dropped"].contains(mode) ? mode : "doing",
                mode == "claimed" ? "agent:codex:other" : nil, mode == "promoted" ? "ado:42" : nil,
              ])
          }
          let output = try SiltaBinary.run(
            args + ["task", "show", "AC-1"], in: scratch,
            environment: TaskCommandTests.fixed)
          #expect(!output.stdout.contains("next: silta"))
        }
      }
    }
  }
}
