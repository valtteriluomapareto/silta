import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct InboxGroupCommandTests {
  @Test(arguments: [false, true])
  func groupedContractAndEveryNext(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      let actor = TaskCommandTests.fixed.merging(["USER": "acme", "TZ": "Pacific/Honolulu"]) { $1 }
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(args, in: scratch, environment: actor)
      }
      _ = try run(["task", "block", "AC-1", "--on", "ext:acme", "--follow-up", "0d", "-m", "Choose API"])
      _ = try run(["task", "add", "Acme idea"])
      _ = try run(["task", "add", "Acme tracked", "--start"])
      try store.write {
        try $0.database.execute(sql: "UPDATE task SET external_ref='ado:42',claimed_by=NULL,claimed_at=NULL WHERE seq=3")
      }
      let args = ["--ws", "acme", "inbox", "--for", "me"]
      let result = try run(args + (json ? ["--json"] : []))
      #expect(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "inbox-groups.\(json ? "json" : "txt")")
      let data = try TaskStateRegressionTests.data(run(args + ["--json"]))
      let items = try #require(data["items"] as? [[String: Any]])
      #expect(items.compactMap { $0["kind"] as? String } == ["due", "proposal", "promoted"])
      #expect(try run(["--ws", "acme", "task", "ls", "--status", "todo"]).termination == .exit(0))
      for ref in ["AC-1", "AC-2", "AC-3"] {
        #expect(try run(["--ws", "acme", "task", "show", ref]).termination == .exit(0))
      }
      try #require(items.count == 3)
      #expect((items[1]["next"] as? [String])?.first?.hasPrefix("ask human:") == true)
      let refused = try run(["--ws", "acme", "task", "triage", "--accept", "AC-2", "--json"])
      #expect(refused.termination == .exit(3) && refused.stdout.contains("human_only"))
      #expect(try run(["--ws", "acme", "task", "triage", "--accept", "AC-2", "--approved", "Accept AC-2."]).termination == .exit(0))
    }
  }

  @Test func utcFollowUpAppearsAtMidnightWithoutReadWrites() throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      _ = try SiltaBinary.run(["task", "block", "AC-1", "--follow-up", "1d", "-m", "Decision"], in: scratch, environment: TaskCommandTests.fixed)
      func inbox(_ time: String) throws -> [[String: Any]] {
        let output = try SiltaBinary.run(["inbox", "--for", "me", "--json"], in: scratch,
          environment: TaskCommandTests.actor.merging(["USER": "acme", "TZ": "Pacific/Honolulu", "SILTA_NOW": time]) { $1 })
        return try #require(TaskStateRegressionTests.data(output)["items"] as? [[String: Any]])
      }
      let before = try store.read { try Row.fetchAll($0, sql: "SELECT * FROM task_event").description }
      #expect(try inbox("2023-11-14T23:59:59.999Z").isEmpty)
      #expect(try inbox("2023-11-15T00:00:00.000Z").first?["kind"] as? String == "due")
      #expect(try store.read { try Row.fetchAll($0, sql: "SELECT * FROM task_event").description } == before)
    }
  }
}
