import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct DocInboxCommandTests {
  @Test(arguments: [false, true])
  func concreteDocumentPayloadAndEveryReadCommand(json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try fixture(scratch)
      let args = ["--ws", "acme", "inbox", "--for", "me"]
      let result = try run(args + (json ? ["--json"] : []), scratch)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      Golden.forTests().check(result.stdout, "inbox-docs.\(json ? "json" : "txt")")
      let data = try TaskStateRegressionTests.data(run(args + ["--json"], scratch))
      let items = try #require(data["items"] as? [[String: Any]])
      let group = try #require(items.first?["doc_proposal"] as? [String: Any])
      #expect(group["total"] as? Int == 3 && group["omitted"] as? Int == 1)
      let schema = try TaskStateRegressionTests.data(run(["schema", "inbox", "--json"], scratch))
      let commands = try #require(schema["commands"] as? [[String: Any]])
      #expect(ShapeCheck.violations(of: data, against: try #require(commands.first?["data"])) == [])
      let next = try #require(items.first?["next"] as? [String])
      #expect(next.count == 3 && Set(next).count == 3)
      for command in next {
        let script = shellWord(try SiltaBinary.url().path) + String(command.dropFirst(5))
        let replay = try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"), ["-c", script], in: scratch, environment: Self.environment)
        #expect(replay.termination == .exit(0) && replay.stderr.isEmpty)
      }
      let help = try run(["inbox", "--help"], scratch)
      #expect(help.stdout.contains("document proposals"))
      let quiet = try run(args + ["--quiet"], scratch)
      #expect(quiet.stdout == (try run(args, scratch)).stdout)
    }
  }

  func fixture(_ scratch: URL) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: scratch)
    try AcmeDocAttachments.attach("rules", to: "app", in: store)
    try store.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
          SELECT 'source',id,1,'Acme source','doing','agent:codex:writer',?,? FROM workspace;
          UPDATE doc_rev SET title='Base rules',kind='contract',about_refs='["app:api"]',
            body_md='Base body';
          """, arguments: [TaskCommandTests.fixed["SILTA_NOW"], TaskCommandTests.fixed["SILTA_NOW"]])
      for revision in 2...4 {
        try tx.database.execute(
          sql: """
            INSERT INTO doc_rev(uid,doc_id,rev,base_rev,body_md,state,actor,message,created_at,
              title,kind,about_refs,source_task_id)
            SELECT ?,id,?,1,'New body','proposed','agent:codex:writer','A complete why',?,
              'Base rules','contract','["app:api"]',(SELECT id FROM task WHERE seq=1) FROM doc;
            """, arguments: ["pending-\(revision)", revision, TaskCommandTests.fixed["SILTA_NOW"]])
      }
    }
    return store
  }

  func run(_ args: [String], _ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(args, in: scratch, environment: Self.environment)
  }

  static let environment = TaskCommandTests.fixed.merging([
    "SILTA_ACTOR": "agent:codex:acme", "USER": "acme",
  ]) { $1 }
}
