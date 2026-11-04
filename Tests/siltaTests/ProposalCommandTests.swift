import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ProposalCommandTests {
  static func setup(_ scratch: URL) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(scratch)
    try store.write {
      try $0.database.execute(sql: "UPDATE workspace SET settings='{\"proposals\":\"ask\"}'")
    }
    return store
  }

  @Test(arguments: [false, true])
  func stdinRefusalAndLeadingHyphenRetryAreActionable(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      let binary = shellWord(try SiltaBinary.url().path)
      let command =
        "printf '%s' 'Acme detail' | " + binary
        + " task add -F -" + (json ? " --json" : "") + " -- '-Acme'"
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"), ["-c", command], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(3))
      #expect((json ? result.stderr : result.stdout).isEmpty)
      Golden.forTests().check(
        json ? result.stdout : result.stderr, "task-add-proposal-refused.\(json ? "json" : "txt")")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 0)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
      let file = scratch.appending(path: "body.md")
      try "Acme detail".write(to: file, atomically: true, encoding: .utf8)
      let approved = try SiltaBinary.run(
        ["--ws", "acme", "task", "add", "-F", file.path, "--approved", "Create the Acme task"]
          + (json ? ["--json"] : []) + ["--", "-Acme"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(approved.termination == .exit(0) && approved.stderr.isEmpty)
      Golden.forTests().check(
        approved.stdout, "task-add-proposal-approved.\(json ? "json" : "txt")")
      #expect(try store.read { try String.fetchOne($0, sql: "SELECT title FROM task") } == "-Acme")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT description_md FROM task") }
          == "Acme detail")
    }
  }

  @Test(arguments: [false, true])
  func importConsentAndDryRunReportActualApprovalUse(split: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      let file = scratch.appending(path: "plan.md")
      try "# Acme\n\n- First\n- Second\n".write(to: file, atomically: true, encoding: .utf8)
      let args = ["task", "from-plan", file.path] + (split ? ["--split"] : [])
      let refused = try SiltaBinary.run(
        args + ["--json"], in: scratch, environment: TaskCommandTests.actor)
      #expect(refused.termination == .exit(3))
      #expect(refused.stdout.contains("silta --ws 'acme' task from-plan <file>"))
      let preview = try SiltaBinary.run(
        args + ["--dry-run", "--allow-secret", "--approved", "<unused>", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(preview.termination == .exit(0))
      #expect(preview.stdout.contains("approval_unused") && preview.stdout.contains("proposed"))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 0)
      let approved = try SiltaBinary.run(
        args + ["--approved", "Import Acme work", "--json"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(approved.termination == .exit(0))
      #expect(!approved.stdout.contains("approval_unused"))
      #expect(
        try store.read { try String.fetchAll($0, sql: "SELECT status FROM task") }
          == Array(repeating: "todo", count: split ? 3 : 1))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
    }
  }
}
