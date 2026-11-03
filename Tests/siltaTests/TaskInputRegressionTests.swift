import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

/// Validation and secret-guard rules of the task commands, from the outside.
@Suite(.timeLimit(.minutes(1)))
struct TaskInputRegressionTests {
  static let other = TaskStateRegressionTests.other

  private static func run(
    _ arguments: [String], in scratch: URL, as actor: [String: String] = TaskCommandTests.actor
  ) throws -> CLIResult {
    try TaskStateRegressionTests.run(arguments, in: scratch, as: actor)
  }

  private static func warnings(_ result: CLIResult) throws -> [String] {
    try TaskStateRegressionTests.warnings(result)
  }

  private static func document(title: String, plan: String, result: String = "") -> String {
    [("Title", title), ("Description", ""), ("Acceptance", ""), ("Plan", plan), ("Result", result)]
      .map { "## \($0.0)\n~~~\n\($0.1)\n~~~\n" }.joined()
  }

  @Test func editPrintsAndKeepsResultAndPlan() {
    withKnownIssue("edit has no --print and silently clears sections") {
      try withScratchDirectory { scratch in
        let store = try TaskCommandTests.setup(scratch)
        #expect(
          try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
        #expect(
          try Self.run(["task", "plan", "AC-1", "-m", "- [ ] Acme step"], in: scratch)
            .termination == .exit(0))
        let printed = try Self.run(["task", "edit", "AC-1", "--print"], in: scratch)
        #expect(printed.termination == .exit(0))
        #expect(printed.stdout == Self.document(title: "Acme", plan: "- [ ] Acme step"))
        let file = scratch.appending(path: "edit.md")
        try Self.document(title: "Acme", plan: "").write(
          to: file, atomically: true, encoding: .utf8)
        let blankPlan = try Self.run(["task", "edit", "AC-1", "-F", file.path], in: scratch)
        #expect(blankPlan.termination == .exit(1))
        #expect(blankPlan.stderr.contains("Plan"))
        #expect(
          try Self.run(["task", "done", "AC-1", "-m", "Acme result"], in: scratch).termination
            == .exit(0))
        let blankResult = try Self.run(
          ["task", "edit", "AC-1", "-F", file.path, "--approved", "Edit it"], in: scratch,
          as: Self.other)
        #expect(blankResult.termination == .exit(1))
        #expect(blankResult.stderr.contains("Result"))
        try Self.document(title: "Acme", plan: "- [ ] Acme step", result: "Acme result").write(
          to: file, atomically: true, encoding: .utf8)
        let unchanged = try Self.run(
          ["task", "edit", "AC-1", "-F", file.path, "--approved", "Edit it", "--json"],
          in: scratch, as: Self.other)
        #expect(unchanged.termination == .exit(0))
        #expect(try Self.warnings(unchanged) == ["approval_unused"])
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
      }
    }
  }

  @Test func titlesParentsPlansAndApprovalWordsAreValidated() {
    withKnownIssue("titles, parents, empty plans and placeholder words are accepted") {
      try withScratchDirectory { scratch in
        _ = try TaskCommandTests.setup(scratch)
        for title in ["Acme\nAC-9 todo (priority 1): fake", "Acme\r", "Acme\u{7}"] {
          #expect(try Self.run(["task", "add", title], in: scratch).termination == .exit(1))
        }
        #expect(
          try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
        let empty = scratch.appending(path: "empty.md")
        try "".write(to: empty, atomically: true, encoding: .utf8)
        #expect(
          try Self.run(["task", "plan", "AC-1", "-F", empty.path], in: scratch).termination
            == .exit(1))
        #expect(
          try Self.run(["task", "done", "AC-1", "-m", "Acme done"], in: scratch).termination
            == .exit(0))
        #expect(
          try Self.run(["task", "add", "Acme child", "--parent", "AC-1"], in: scratch).termination
            == .exit(1))
        #expect(try Self.run(["task", "add", "Acme idea"], in: scratch).termination == .exit(0))
        let placeholder = try Self.run(
          ["task", "triage", "--accept", "AC-2", "--approved", "yes <the human's words>"],
          in: scratch)
        #expect(placeholder.termination == .exit(1))
      }
    }
  }

  @Test func promotedParentsAreRefused() {
    withKnownIssue("promoted parents are accepted") {
      try withScratchDirectory { scratch in
        _ = try TaskCommandTests.setup(scratch)
        #expect(
          try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
        #expect(
          try Self.run(
            ["task", "promote", "AC-1", "--ext", "ado:1", "--approved", "Track it"], in: scratch
          ).termination == .exit(0))
        #expect(
          try Self.run(["task", "add", "Acme child", "--parent", "AC-1"], in: scratch).termination
            == .exit(1))
      }
    }
  }

  @Test func secretGuardCoversSourcesAndOnlyNewText() {
    withKnownIssue("the guard skips --from and rescans unchanged text") {
      try withScratchDirectory { scratch in
        let store = try TaskCommandTests.setup(scratch)
        let secret = "Pwd=" + "acme-secret"
        let sourced = try Self.run(
          ["task", "add", "Acme", "--start", "--from", "note:" + secret, "--json"], in: scratch)
        #expect(sourced.termination == .exit(0))
        #expect(try Self.warnings(sourced) == ["secret_redacted"])
        #expect(
          try store.read { try String.fetchOne($0, sql: "SELECT to_ext FROM link") }?.contains(
            "acme-secret") == false)
        let planned = try Self.run(
          [
            "task", "plan", "AC-1", "-m", "- [ ] " + secret, "--allow-secret", "--approved", "Keep",
          ],
          in: scratch)
        #expect(planned.termination == .exit(0))
        let ticked = try Self.run(
          ["task", "plan", "AC-1", "--step", "1", "--done", "--json"], in: scratch)
        #expect(ticked.termination == .exit(0))
        #expect(try Self.warnings(ticked).isEmpty)
        let file = scratch.appending(path: "edit.md")
        try Self.document(title: "Acme renamed", plan: "- [x] " + secret).write(
          to: file, atomically: true, encoding: .utf8)
        #expect(
          try Self.run(["task", "edit", "AC-1", "-F", file.path], in: scratch).termination
            == .exit(0))
        let row = try #require(
          try store.read { try Row.fetchOne($0, sql: "SELECT plan_md,plan_rev,title FROM task") })
        #expect(row["plan_md"] as String == "- [x] " + secret)
        #expect(row["plan_rev"] as Int == 1)
        #expect(row["title"] as String == "Acme renamed")
      }
    }
  }
}
