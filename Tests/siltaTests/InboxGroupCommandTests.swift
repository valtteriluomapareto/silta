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
      _ = try run([
        "task", "block", "AC-1", "--on", "ext:acme", "--follow-up", "0d", "-m", "Choose API",
      ])
      _ = try run(["task", "add", "Acme idea"])
      _ = try run(["task", "add", "Acme tracked", "--start"])
      try store.write {
        try $0.database.execute(
          sql: "UPDATE task SET external_ref='ado:42',claimed_by=NULL,claimed_at=NULL WHERE seq=3")
      }
      let args = ["--ws", "acme", "inbox", "--for", "me"]
      let result = try run(args + (json ? ["--json"] : []))
      #expect(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "inbox-groups.\(json ? "json" : "txt")")
      let data = try TaskStateRegressionTests.data(run(args + ["--json"]))
      let items = try #require(data["items"] as? [[String: Any]])
      let schema = try TaskStateRegressionTests.data(run(["schema", "inbox", "--json"]))
      let commands = try #require(schema["commands"] as? [[String: Any]])
      #expect(ShapeCheck.violations(of: data, against: try #require(commands.first?["data"])) == [])
      #expect(items.compactMap { $0["kind"] as? String } == ["due", "proposal", "promoted"])
      #expect(try run(["--ws", "acme", "task", "ls", "--status", "todo"]).termination == .exit(0))
      for ref in ["AC-1", "AC-2", "AC-3"] {
        #expect(try run(["--ws", "acme", "task", "show", ref]).termination == .exit(0))
      }
      try #require(items.count == 3)
      #expect((items[1]["next"] as? [String])?.first?.hasPrefix("ask human:") == true)
      let refused = try run(["--ws", "acme", "task", "triage", "--accept", "AC-2", "--json"])
      #expect(refused.termination == .exit(3) && refused.stdout.contains("human_only"))
      #expect(
        try run([
          "--ws", "acme", "task", "triage", "--accept", "AC-2", "--approved", "Accept AC-2.",
        ]).termination == .exit(0))
    }
  }

  @Test func utcFollowUpAppearsAtMidnightWithoutReadWrites() throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      _ = try SiltaBinary.run(
        ["task", "block", "AC-1", "--follow-up", "1d", "-m", "Decision"], in: scratch,
        environment: TaskCommandTests.fixed)
      func inbox(_ time: String) throws -> [[String: Any]] {
        let output = try SiltaBinary.run(
          ["inbox", "--for", "me", "--json"], in: scratch,
          environment: TaskCommandTests.actor.merging([
            "USER": "acme", "TZ": "Pacific/Honolulu", "SILTA_NOW": time,
          ]) { $1 })
        return try #require(TaskStateRegressionTests.data(output)["items"] as? [[String: Any]])
      }
      let before = try store.read {
        try Row.fetchAll($0, sql: "SELECT * FROM task_event").description
      }
      #expect(try inbox("2023-11-14T23:59:59.998Z").isEmpty)
      #expect(try inbox("2023-11-15T00:00:00.000Z").first?["kind"] as? String == "due")
      #expect(
        try store.read { try Row.fetchAll($0, sql: "SELECT * FROM task_event").description }
          == before)
    }
  }
  @Test func cappedProposalRelayTouchesOnlyShownRefs() throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      let env = TaskCommandTests.fixed.merging(["USER": "acme"]) { $1 }
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(["--ws", "acme"] + args, in: scratch, environment: env)
      }
      for _ in 0..<15 { #expect(try run(["task", "add", "Acme idea"]).termination == .exit(0)) }
      try store.write {
        try $0.database.execute(
          sql: "UPDATE task SET created_at='2023-10-01T00:00:00.000Z' WHERE seq=2")
      }
      let result = try TaskStateRegressionTests.data(run(["inbox", "--for", "me", "--json"]))
      let items = try #require(result["items"] as? [[String: Any]])
      #expect(items.compactMap { $0["ref"] as? String } == (5...16).reversed().map { "AC-\($0)" })
      #expect(result["remaining"] as? Int == 2)
      #expect(result["more"] as? String == "silta --ws 'acme' inbox --for 'human:acme' --all")
      let accept =
        "silta --ws 'acme' task triage --accept 'AC-16' --approved \"<the human's words>\""
      let drop = "silta --ws 'acme' task triage --drop 'AC-15' --approved \"<the human's words>\""
      try #require(items.count == 12)
      #expect((items[0]["next"] as? [String])?.first?.contains(accept) == true)
      #expect((items[1]["next"] as? [String])?.first?.contains(drop) == true)
      let words = "Accept AC-16 and drop AC-15."
      #expect(
        try run(["task", "triage", "--accept", "AC-16", "--drop", "AC-15", "--approved", words])
          .termination == .exit(0))
      let statuses = try store.read {
        try String.fetchAll($0, sql: "SELECT status FROM task WHERE seq IN (2,3,4) ORDER BY seq")
      }
      #expect(statuses == ["proposed", "proposed", "proposed"])
      let all = try TaskStateRegressionTests.data(
        run(["inbox", "--for", "human:acme", "--all", "--json"]))
      #expect((all["items"] as? [Any])?.count == 13 && all["more"] == nil)
    }
  }

}
