import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

/// What task commands print: one-line receipts that say what changed, data that
/// `--quiet` keeps, and approval rows that name the body flag passed.
@Suite(.timeLimit(.minutes(1)))
struct TaskOutputCommandTests {
  private static func run(_ arguments: [String], in scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(arguments, in: scratch, environment: TaskCommandTests.actor)
  }

  @Test func showNumbersTheCheckboxesStepCounts() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
      let plan = "Context\n\n- [ ] Write\n- [x] Ship\n  - [ ] Nested"
      #expect(
        try Self.run(["task", "plan", "AC-1", "-m", plan], in: scratch).termination == .exit(0))
      let shown = try Self.run(["task", "show", "AC-1"], in: scratch)
      #expect(shown.termination == .exit(0))
      withKnownIssue("show prints the plan without step numbers") {
        Golden.forTests().check(shown.stdout, "task-show-plan.txt")
      }
    }
  }

  @Test func aStepOnAPlanWithoutCheckboxesPointsAtANewRevision() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
      #expect(
        try Self.run(["task", "plan", "AC-1", "-m", "- First"], in: scratch).termination
          == .exit(0))
      let refused = try Self.run(
        ["task", "plan", "AC-1", "--step", "1", "--done"], in: scratch)
      #expect(refused.termination == .exit(1))
      withKnownIssue("the refusal points at --help") {
        #expect(refused.stderr.contains("0 checkboxes"))
        #expect(refused.stderr.hasSuffix("next: silta --ws 'acme' task plan AC-1 -F -\n"))
      }
    }
  }

  @Test func blockAsksOnlyThePartiesThisCallNames() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
      #expect(
        try Self.run(
          ["task", "block", "AC-1", "--on", "ext:acme", "-m", "Which push?"], in: scratch
        )
        .termination == .exit(0))
      let again = try Self.run(
        ["task", "block", "AC-1", "--on", "ext:beta", "-m", "Which build?"], in: scratch)
      #expect(again.termination == .exit(0))
      #expect(again.stdout.contains("ask ext:beta: Which build?"))
      withKnownIssue("every party gets the latest ask") {
        #expect(!again.stdout.contains("ask ext:acme"))
      }
    }
  }

  @Test func timelineTextHasNoTrailingSpaces() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      for arguments in [
        ["task", "add", "Acme", "--start"], ["task", "block", "AC-1", "-m", "Which push?"],
        ["task", "unblock", "AC-1", "--approved", "Unblock it"],
      ] {
        #expect(try Self.run(arguments, in: scratch).termination == .exit(0))
      }
      let shown = try Self.run(["task", "show", "AC-1", "--timeline"], in: scratch)
      #expect(shown.termination == .exit(0))
      withKnownIssue("an event without a body ends in a space") {
        #expect(!shown.stdout.split(separator: "\n").contains { $0.hasSuffix(" ") })
      }
    }
  }

  @Test func quietKeepsCreatedRefsAndReads() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let added = try Self.run(["task", "add", "Acme", "--start", "--quiet"], in: scratch)
      #expect(added.termination == .exit(0))
      let file = scratch.appending(path: "plan.md")
      try "# Acme import\n\n- First\n".write(to: file, atomically: true, encoding: .utf8)
      let imported = try Self.run(["task", "from-plan", file.path, "--quiet"], in: scratch)
      #expect(imported.termination == .exit(0))
      let listed = try Self.run(["task", "ls"], in: scratch)
      let shown = try Self.run(["task", "show", "AC-1"], in: scratch)
      let quietList = try Self.run(["task", "ls", "--quiet"], in: scratch)
      let quietShow = try Self.run(["--quiet", "task", "show", "AC-1"], in: scratch)
      let archived = try Self.run(["task", "archive", "AC-1", "--quiet"], in: scratch)
      #expect(archived.termination == .exit(0) && archived.stdout.isEmpty)
      withKnownIssue("--quiet hides data") {
        #expect(added.stdout == "AC-1\n")
        #expect(imported.stdout == "AC-2\n")
        #expect(quietList.stdout == listed.stdout && !listed.stdout.isEmpty)
        #expect(quietShow.stdout == shown.stdout && !shown.stdout.isEmpty)
      }
    }
  }

  @Test func schemaSplitsOneQuotedName() throws {
    try withScratchDirectory { scratch in
      let words = try SiltaBinary.run(["schema", "task", "add"], in: scratch)
      let quoted = try SiltaBinary.run(["schema", "task add"], in: scratch)
      #expect(words.termination == .exit(0))
      withKnownIssue("a quoted name is one word") {
        #expect(quoted.termination == .exit(0))
        #expect(quoted.stdout == words.stdout)
      }
    }
  }

  @Test func anUnknownWorkspaceIsNamed() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let refused = try Self.run(["--ws", "acme-two", "task", "ls"], in: scratch)
      #expect(refused.termination == .exit(2))
      withKnownIssue("the message doesn't name the workspace") {
        #expect(refused.stderr.contains("acme-two"))
      }
    }
  }

  @Test func approvalRowsNameTheBodyFlagPassed() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      #expect(
        try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
      let file = scratch.appending(path: "edit.md")
      let printed = try Self.run(["task", "edit", "AC-1", "--print"], in: scratch)
      try printed.stdout.replacingOccurrences(of: "\nAcme\n", with: "\nAcme edited\n")
        .write(to: file, atomically: true, encoding: .utf8)
      for arguments in [
        ["task", "edit", "AC-1", "-F", file.path, "--allow-secret", "--approved", "Edit it"],
        ["task", "block", "AC-1", "--on", "ext:acme", "-m", "Which push?"],
        ["task", "unblock", "AC-1", "-m", "Answered", "--approved", "Unblock it"],
        ["task", "done", "AC-1", "--allow-secret", "-m", "Done", "--approved", "Close it"],
      ] {
        #expect(try Self.run(arguments, in: scratch).termination == .exit(0))
      }
      let commands = try store.read {
        try String.fetchAll($0, sql: "SELECT command FROM approval ORDER BY id")
      }
      withKnownIssue("approval rows leave out the body flag") {
        #expect(
          commands == [
            "silta task edit 'AC-1' --allow-secret -F <file>",
            "silta task unblock 'AC-1' -m <text>",
            "silta task done 'AC-1' --allow-secret -m <text>",
          ])
      }
    }
  }

  @Test func aDryRunDoesNotUseItsApproval() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let file = scratch.appending(path: "plan.md")
      try "# Acme import\n\n- First\n".write(to: file, atomically: true, encoding: .utf8)
      let preview = try Self.run(
        [
          "task", "from-plan", file.path, "--dry-run", "--allow-secret", "--approved",
          "Preview it", "--json",
        ], in: scratch)
      #expect(preview.termination == .exit(0))
      let warnings = try TaskStateRegressionTests.warnings(preview)
      withKnownIssue("a dry run reports its approval as used") {
        #expect(warnings == ["approval_unused"])
      }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }
}
