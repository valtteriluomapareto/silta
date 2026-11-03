import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

/// When task commands need the human's go-ahead, and what their approval rows record.
@Suite(.timeLimit(.minutes(1)))
struct TaskApprovalRegressionTests {
  static let other = TaskStateRegressionTests.other

  private static func run(
    _ arguments: [String], in scratch: URL, as actor: [String: String] = TaskCommandTests.actor
  ) throws -> CLIResult {
    try TaskStateRegressionTests.run(arguments, in: scratch, as: actor)
  }

  private static func error(_ result: CLIResult) throws -> [String: Any] {
    try TaskStateRegressionTests.error(result)
  }

  private static func warnings(_ result: CLIResult) throws -> [String] {
    try TaskStateRegressionTests.warnings(result)
  }

  @Test func approvalRowsNameTheTasksTheyCreated() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let secret = "Pwd=" + "acme-secret"
      let added = try Self.run(
        ["task", "add", "Acme", "-m", secret, "--allow-secret", "--approved", "Keep it"],
        in: scratch)
      #expect(added.termination == .exit(0))
      let plan = scratch.appending(path: "plan.md")
      try "# Acme import\n\n- First\n".write(to: plan, atomically: true, encoding: .utf8)
      let imported = try Self.run(
        ["task", "from-plan", plan.path, "--allow-secret", "--approved", "Import it"],
        in: scratch)
      #expect(imported.termination == .exit(0))
      let commands = try store.read {
        try String.fetchAll($0, sql: "SELECT command FROM approval ORDER BY id")
      }
      #expect(
        commands == [
          "silta task add --allow-secret -> AC-1", "silta task from-plan --allow-secret -> AC-2",
        ])
    }
  }

  @Test func unblockingAnOpenBlockNeedsTheHuman() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      for title in ["Acme", "Acme two", "Acme three"] {
        #expect(
          try Self.run(["task", "add", title, "--start"], in: scratch).termination == .exit(0))
      }
      #expect(
        try Self.run(["task", "block", "AC-1", "--on", "ext:acme", "-m", "Acme?"], in: scratch)
          .termination == .exit(0))
      let refused = try Self.run(["task", "unblock", "AC-1", "--json"], in: scratch)
      #expect(refused.termination == .exit(3))
      #expect(try Self.error(refused)["code"] as? String == "human_only")
      #expect(
        try Self.run(["task", "show", "AC-1", "--json"], in: scratch).stdout.contains(
          "\"status\":\"blocked\""))
      let approved = try Self.run(
        ["task", "unblock", "AC-1", "--approved", "Acme answered"], in: scratch)
      #expect(approved.termination == .exit(0))
      #expect(
        try Self.run(["task", "block", "AC-3", "--on", "AC-2", "-m", "After two"], in: scratch)
          .termination == .exit(0))
      #expect(
        try Self.run(["task", "done", "AC-2", "-m", "Acme two done"], in: scratch).termination
          == .exit(0))
      let ready = try Self.run(
        ["task", "unblock", "AC-3", "--approved", "Unused", "--json"], in: scratch)
      #expect(ready.termination == .exit(0))
      #expect(try Self.warnings(ready) == ["approval_unused"])
      let commands = try store.read {
        try String.fetchAll($0, sql: "SELECT command FROM approval")
      }
      #expect(commands == ["silta task unblock 'AC-1'"])
    }
  }

  @Test func forceAndStealNeedApprovalOnlyWhenTheyBypass() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      #expect(try Self.run(["task", "add", "Acme"], in: scratch).termination == .exit(0))
      #expect(
        try Self.run(["task", "triage", "--accept", "AC-1", "--approved", "Yes"], in: scratch)
          .termination == .exit(0))
      #expect(
        try Self.run(["task", "start", "AC-1", "--steal"], in: scratch).termination == .exit(0))
      #expect(
        try Self.run(["task", "done", "AC-1", "--force", "-m", "Acme done"], in: scratch)
          .termination == .exit(0))
      #expect(
        try Self.run(["task", "add", "Acme held", "--start"], in: scratch, as: Self.other)
          .termination == .exit(0))
      let refused = try Self.run(["task", "start", "AC-2", "--steal"], in: scratch)
      #expect(refused.termination == .exit(3))
      let stolen = try Self.run(
        ["task", "start", "AC-2", "--steal", "--approved", "Take it over"], in: scratch)
      #expect(stolen.termination == .exit(0))
      let commands = try store.read {
        try String.fetchAll($0, sql: "SELECT command FROM approval ORDER BY id")
      }
      #expect(
        commands == ["silta task triage --accept 'AC-1'", "silta task start 'AC-2' --steal"])
    }
  }
}
