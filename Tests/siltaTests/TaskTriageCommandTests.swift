import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskTriageCommandTests {
  @Test func approvalRetryRetainsBothSetsPriorityWorkspaceAndSecretOption() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      for title in ["Acme first", "Acme second"] {
        #expect(
          try SiltaBinary.run(
            ["task", "add", title], in: scratch,
            environment: TaskCommandTests.actor
          ).termination == .exit(0))
      }
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix)
            VALUES('acme-beta','beta','Acme beta','BE');
            UPDATE meta SET value='beta' WHERE key='current_workspace';
            """)
      }
      let args = [
        "--ws", "acme", "task", "triage", "--accept", "AC-1", "--drop", "AC-2",
        "--priority", "3", "--allow-secret", "-m", "Pwd=acme-secret",
      ]
      let refused = try SiltaBinary.run(
        args + ["--json"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(refused.termination == .exit(3))
      Golden.forTests().check(refused.stdout, "task-triage-refused.json")
      let envelope = try #require(
        JSONSerialization.jsonObject(with: Data(refused.stdout.utf8)) as? [String: Any])
      let error = try #require(envelope["error"] as? [String: Any])
      let next = try #require((error["next"] as? [String])?.first)
      let file = scratch.appending(path: "why.md")
      try "Pwd=acme-secret".write(to: file, atomically: true, encoding: .utf8)
      let command = shellWord(try SiltaBinary.url().path) + String(next.dropFirst(5))
      let replay = command.replacingOccurrences(of: "<file>", with: shellWord(file.path))
        .replacingOccurrences(
          of: "<the human's words>", with: "Accept the first and drop the second")
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", replay],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(0))
      try Self.checkRows(store)
    }
  }

  private static func checkRows(_ store: DatabaseStore) throws {
    try store.read { db in
      let rows = try Row.fetchAll(db, sql: "SELECT * FROM task ORDER BY seq")
      #expect(rows.map { $0["status"] as String } == ["todo", "dropped"])
      #expect(rows.map { $0["priority"] as Int } == [3, 2])
      #expect(rows[1]["result_md"] as String? == "Pwd=acme-secret")
      let approvals = try Int.fetchOne(db, sql: "SELECT count(*) FROM approval")
      #expect(approvals == 1)
      let audit = try #require(try String.fetchOne(db, sql: "SELECT command FROM approval"))
      #expect(audit.contains("--allow-secret"))
      #expect(!audit.contains("acme-secret"))
    }
  }
}
