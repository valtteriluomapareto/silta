import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskOrganizationCommandTests {
  private static func writeDocument(to file: URL) throws {
    try """
    ## Title
    ~~~
    Acme edited
    ~~~
    ## Description
    ~~~
    Acme description
    ~~~
    ## Acceptance
    ~~~
    Acme acceptance
    ~~~
    ## Plan
    ~~~
    - [ ] Acme step
    ~~~
    ## Result
    ~~~

    ~~~
    """.write(to: file, atomically: true, encoding: .utf8)
  }

  @Test(arguments: [false, true]) func organizationCommandsRoundTrip(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(
          args + (json ? ["--json"] : []), in: scratch, environment: TaskCommandTests.actor)
      }
      #expect(try run(["task", "add", "Acme idea", "--priority", "1"]).termination == .exit(0))
      let triage = try run([
        "task", "triage", "--accept", "AC-1", "--approved", "Accept the Acme idea",
      ])
      #expect(triage.termination == .exit(0))
      Golden.forTests().check(triage.stdout, "task-triage" + (json ? ".json" : ".txt"))
      #expect(try run(["task", "start", "AC-1"]).termination == .exit(0))
      let file = scratch.appending(path: "edit.md")
      try Self.writeDocument(to: file)
      let edited = try run(["task", "edit", "AC-1", "-F", file.path])
      #expect(edited.termination == .exit(0))
      withKnownIssue("receipts print only the status") {
        Golden.forTests().check(edited.stdout, "task-edit" + (json ? ".json" : ".txt"))
      } when: {
        !json
      }
      for command in ["archive", "keep"] {
        let result = try run(["task", command, "AC-1"])
        #expect(result.termination == .exit(0))
        withKnownIssue("receipts print only the status") {
          Golden.forTests().check(result.stdout, "task-\(command)" + (json ? ".json" : ".txt"))
        } when: {
          !json
        }
      }
      let linked = try run(["task", "link", "AC-1", "plan#L1"])
      #expect(linked.termination == .exit(0))
      withKnownIssue("receipts print only the status") {
        Golden.forTests().check(linked.stdout, "task-link" + (json ? ".json" : ".txt"))
      } when: {
        !json
      }
      let promoted = try run([
        "task", "promote", "AC-1", "--ext", "ado:42", "--approved", "Track Acme in ADO",
      ])
      #expect(promoted.termination == .exit(0))
      withKnownIssue("receipts print only the status") {
        Golden.forTests().check(promoted.stdout, "task-promote" + (json ? ".json" : ".txt"))
      } when: {
        !json
      }
      let listed = try SiltaBinary.run(
        ["task", "ls", "--promoted"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(listed.stdout.contains("[read-only: ado:42]"))
      let refused = try run(["task", "plan", "AC-1", "-m", "Changed"])
      #expect(refused.termination == .exit(3))
      #expect((refused.stdout + refused.stderr).contains("read_only_promoted"))
      try store.read { db in
        let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM task"))
        #expect(row["acceptance_md"] as String == "Acme acceptance")
        #expect(row["plan_rev"] as Int == 1)
        #expect(row["external_ref"] as String? == "ado:42")
        #expect(row["claimed_by"] as String? == nil)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 2)
      }
    }
  }
}
