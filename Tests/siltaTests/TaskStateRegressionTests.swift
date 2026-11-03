import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

/// State-machine, permanence and approval rules of the task commands, from the outside.
@Suite(.timeLimit(.minutes(1)))
struct TaskStateRegressionTests {
  static let other = ["SILTA_ACTOR": "agent:codex:other"]

  static func run(
    _ arguments: [String], in scratch: URL, as actor: [String: String] = TaskCommandTests.actor
  ) throws -> CLIResult {
    try SiltaBinary.run(arguments, in: scratch, environment: actor)
  }

  static func object(_ result: CLIResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
  }

  static func data(_ result: CLIResult) throws -> [String: Any] {
    try #require(try object(result)["data"] as? [String: Any])
  }

  static func error(_ result: CLIResult) throws -> [String: Any] {
    try #require(try object(result)["error"] as? [String: Any])
  }

  static func warnings(_ result: CLIResult) throws -> [String] {
    try #require(try object(result)["warnings"] as? [[String: Any]]).compactMap {
      $0["code"] as? String
    }
  }

  static func tasks(_ result: CLIResult) throws -> [[String: Any]] {
    try #require(try data(result)["tasks"] as? [[String: Any]])
  }

  @Test func statusEventBodyIsTheNewStatus() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      #expect(
        try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
      let noted = try Self.run(["task", "submit", "AC-1", "-m", "Acme note"], in: scratch)
      #expect(noted.termination == .exit(1))
      #expect(try Self.run(["task", "submit", "AC-1"], in: scratch).termination == .exit(0))
      let bodies = try store.read {
        try String?.fetchAll($0, sql: "SELECT body FROM task_event WHERE kind='status'")
      }
      #expect(bodies == ["review"])
    }
  }

  @Test func listJSONIsASummaryWithoutBodies() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let added = try Self.run(["task", "add", "Acme", "-m", "Acme detail"], in: scratch)
      #expect(added.termination == .exit(0))
      let listed = try Self.tasks(Self.run(["task", "ls", "--json"], in: scratch))
      #expect(
        Set(try #require(listed.first).keys)
          == [
            "archived", "created_at", "created_by", "links", "priority", "ref", "status", "title",
            "updated_at",
          ])
    }
  }

  @Test func promoteRefusesProposalsAndBlockedTasks() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(try Self.run(["task", "add", "Acme idea"], in: scratch).termination == .exit(0))
      let proposal = try Self.run(
        ["task", "promote", "AC-1", "--ext", "ado:1", "--approved", "Track it", "--json"],
        in: scratch)
      #expect(proposal.termination == .exit(6))
      #expect(try Self.error(proposal)["code"] as? String == "conflict")
      #expect(
        (try Self.error(proposal)["next"] as? [String])?.first?.contains(
          "task triage --accept AC-1 --approved") == true)
      #expect(
        try Self.run(["task", "add", "Acme work", "--start"], in: scratch).termination
          == .exit(0))
      #expect(
        try Self.run(["task", "block", "AC-2", "--on", "ext:acme", "-m", "Acme?"], in: scratch)
          .termination == .exit(0))
      let blocked = try Self.run(
        ["task", "promote", "AC-2", "--ext", "ado:2", "--approved", "Track it", "--json"],
        in: scratch)
      #expect(blocked.termination == .exit(6))
      #expect(try Self.error(blocked)["code"] as? String == "conflict")
      #expect(
        (try Self.error(blocked)["next"] as? [String])?.first?.contains("task unblock AC-2")
          == true)
    }
  }

  @Test func triageWithoutPriorityKeepsTheStoredPriority() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try Self.run(["task", "add", "Acme", "--priority", "1"], in: scratch).termination
          == .exit(0))
      let triaged = try Self.run(
        ["task", "triage", "--accept", "AC-1", "--approved", "Accept it"], in: scratch)
      #expect(triaged.termination == .exit(0))
      let shown = try Self.data(Self.run(["task", "show", "AC-1", "--json"], in: scratch))
      #expect(shown["priority"] as? Int == 1)
    }
  }

  @Test func unreadableBodyFileIsInvalid() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let result = try Self.run(
        ["task", "add", "Acme", "-F", scratch.appending(path: "missing.md").path, "--json"],
        in: scratch)
      #expect(result.termination == .exit(1))
      #expect(try Self.error(result)["code"] as? String == "invalid")
      #expect(
        try Self.error(result)["next"] as? [String] == ["silta --ws 'acme' task add --help"])
    }
  }

  @Test func splitChildrenTakeTheRootsStatus() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
      let plan = scratch.appending(path: "plan.md")
      try "# Acme import\n\n- First\n- Second\n".write(
        to: plan, atomically: true, encoding: .utf8)
      let preview = try Self.data(
        Self.run(
          ["task", "from-plan", plan.path, "--split", "--parent", "AC-1", "--dry-run", "--json"],
          in: scratch))
      let previewed = try #require(preview["preview"] as? [String: Any])
      #expect(previewed["status"] as? String == "todo")
      let steps = try #require(previewed["steps"] as? [[String: Any]])
      #expect(steps.compactMap { $0["status"] as? String } == ["todo", "todo"])
      let created = try Self.tasks(
        Self.run(
          ["task", "from-plan", plan.path, "--split", "--parent", "AC-1", "--json"], in: scratch))
      #expect(created.compactMap { $0["status"] as? String } == ["todo", "todo", "todo"])
    }
  }

  @Test func parentAppearsInListAndShow() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
      #expect(
        try Self.run(["task", "add", "Acme child", "--parent", "AC-1"], in: scratch).termination
          == .exit(0))
      let shown = try Self.data(Self.run(["task", "show", "AC-2", "--json"], in: scratch))
      #expect(shown["parent"] as? String == "AC-1")
      let listed = try Self.tasks(Self.run(["task", "ls", "--json"], in: scratch))
      #expect(listed.map { $0["parent"] as? String } == [nil, "AC-1"])
      let text = try Self.run(["task", "show", "AC-2"], in: scratch)
      #expect(text.stdout.hasPrefix("AC-2 todo (priority 2, parent AC-1): Acme child\n"))
    }
  }

  @Test func promotedTasksLeaveTheBacklog() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(try Self.run(["task", "add", "Acme"], in: scratch).termination == .exit(0))
      for args in [
        ["task", "triage", "--accept", "AC-1"], ["task", "promote", "AC-1", "--ext", "ado:1"],
      ] {
        #expect(
          try Self.run(args + ["--approved", "Do it"], in: scratch).termination == .exit(0))
      }
      let todo = try Self.run(["task", "ls", "--status", "todo", "--json"], in: scratch)
      #expect(try Self.tasks(todo).isEmpty)
      let promoted = try Self.run(
        ["task", "ls", "--status", "todo", "--promoted", "--json"], in: scratch)
      #expect(try Self.tasks(promoted).map { $0["ref"] as? String } == ["AC-1"])
      let started = try Self.run(["task", "start", "AC-1", "--json"], in: scratch)
      #expect(started.termination == .exit(3))
      #expect(
        try Self.error(started)["next"] as? [String] == [
          "silta --ws 'acme' task ls --status todo"
        ])
      #expect(try Self.error(started)["next_by"] as? String == "agent")
    }
  }

  @Test func proposalsStayListedAndRefusalNamesTheTriage() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try Self.run(["task", "add", "Acme idea"], in: scratch, as: Self.other).termination
          == .exit(0))
      let listed = try Self.run(["task", "ls", "--status", "proposed", "--json"], in: scratch)
      #expect(try Self.tasks(listed).map { $0["ref"] as? String } == ["AC-1"])
      let started = try Self.run(["task", "start", "AC-1", "--json"], in: scratch)
      #expect(started.termination == .exit(6))
      #expect(
        (try Self.error(started)["next"] as? [String])?.first
          == "silta --ws 'acme' task triage --accept AC-1 --approved \"<the human's words>\"")
    }
  }

}

extension TaskStateRegressionTests {
  @Test func listSummaryKeepsLinksAndArchived() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try Self.run(["task", "add", "Acme", "--start"], in: scratch).termination == .exit(0))
      let url = "url:https://example.com/acme/issues/4"
      #expect(try Self.run(["task", "link", "AC-1", url], in: scratch).termination == .exit(0))
      let listed = try Self.tasks(Self.run(["task", "ls", "--json"], in: scratch))
      let task = try #require(listed.first)
      #expect(task["archived"] as? Bool == false)
      let links = try #require(task["links"] as? [[String: String]])
      #expect(links == [["rel": "cites", "target": url]])
    }
  }

  @Test func proposalRefusalAsksTheHuman() {
    withKnownIssue("the triage next needs the human's words but says next_by agent") {
      try withScratchDirectory { scratch in
        _ = try TaskCommandTests.setup(scratch)
        #expect(try Self.run(["task", "add", "Acme idea"], in: scratch).termination == .exit(0))
        let started = try Self.run(["task", "start", "AC-1", "--json"], in: scratch)
        #expect(try Self.error(started)["next_by"] as? String == "human")
        #expect(
          try Self.error(started)["next"] as? [String] == [
            "silta --ws 'acme' task triage --accept AC-1 --approved \"<the human's words>\""
          ])
        let text = try Self.run(["task", "start", "AC-1"], in: scratch)
        #expect(text.stderr.contains("ask human: silta --ws 'acme' task triage --accept AC-1"))
      }
    }
  }

  @Test func unblockRefusalNamesTheTasksThatAreNotReady() {
    withKnownIssue("the unblock refusal doesn't say which tasks aren't ready") {
      try withScratchDirectory { scratch in
        _ = try TaskCommandTests.setup(scratch)
        for title in ["Acme", "Acme two", "Acme three"] {
          #expect(
            try Self.run(["task", "add", title, "--start"], in: scratch).termination == .exit(0))
        }
        for ref in ["AC-1", "AC-3"] {
          #expect(
            try Self.run(["task", "block", ref, "--on", "ext:acme", "-m", "Acme?"], in: scratch)
              .termination == .exit(0))
        }
        let refused = try Self.run(["task", "unblock", "AC-1", "AC-3", "--json"], in: scratch)
        #expect(refused.termination == .exit(3))
        #expect(
          (try Self.error(refused)["message"] as? String)?.hasPrefix(
            "AC-1 and AC-3 still wait on open blockers") == true)
      }
    }
  }
}
