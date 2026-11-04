import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskRecoveryTests {
  @Test func noncurrentWorkspaceSurvivesTaskRecovery() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let add = try SiltaBinary.run(
        ["--ws", "acme", "task", "add", "Acme", "--start", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(add.termination == .exit(0))
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Acme Beta','BT');
            UPDATE meta SET value='beta' WHERE key='current_workspace';
            UPDATE workspace SET settings='{"review_gate":"human"}' WHERE slug='acme';
            """)
      }
      let rival = ["SILTA_ACTOR": ActorID.agent(tool: "codex", session: "rival").description]
      for json in [false, true] {
        let result = try SiltaBinary.run(
          ["--ws", "acme", "task", "start", "AC-1"] + (json ? ["--json"] : []),
          in: scratch, environment: rival)
        #expect(result.termination == .exit(6))
        #expect(
          (json ? result.stdout : result.stderr).contains("silta --ws 'acme' task ls --status todo")
        )
        #expect(
          (json ? result.stdout : result.stderr).contains(
            "silta --ws 'acme' task start AC-1 --steal"))
        let retry = try SiltaBinary.run(
          ["--ws", "acme", "task", "show", "AC-1", "--json"], in: scratch)
        #expect(retry.termination == .exit(0))
      }
      // Each flag bypasses something here: the rival steals a fresh claim, and the holder
      // forces past an unmet human review gate.
      for (args, actor, expected) in [
        (
          ["task", "start", "AC-1", "--steal"], rival,
          "silta --ws 'acme' task start 'AC-1' --steal"
        ),
        (
          ["task", "done", "AC-1", "--force", "-m", "Acme done"], TaskCommandTests.actor,
          "silta --ws 'acme' task done 'AC-1' --force -F <file>"
        ),
      ] {
        let result = try SiltaBinary.run(
          ["--ws", "acme"] + args + ["--json"], in: scratch, environment: actor)
        #expect(result.termination == .exit(3))
        #expect(result.stdout.contains(expected))
      }
    }

  }

  @Test(arguments: [
    (["task", "done", "AC-1"], "silta --ws 'acme' task done --help"),
    (["task", "ls", "--status", "typo"], "silta --ws 'acme' task ls --help"),
    (["task", "show", "AC-01"], "silta --ws 'acme' task show --help"),
  ])
  func invalidRecoveryNamesActualCommand(arguments: [String], expected: String) throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let result = try SiltaBinary.run(
        arguments + ["--json"], in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(1))
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let error = try #require(object["error"] as? [String: Any])
      #expect(error["next"] as? [String] == [expected])
    }

  }
}

extension TaskRecoveryTests {
  @Test func addOverrideSkeletonHasTitleAndFileArguments() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(
        ["task", "add", "Acme", "--allow-secret", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(3))
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let error = try #require(object["error"] as? [String: Any])
      #expect(
        error["next"] as? [String] == [
          "silta task add '<title>' --allow-secret -F <file> --approved \"<the human's words>\""
        ])
      let help = try SiltaBinary.run(
        ["task", "add", "Acme", "--allow-secret", "-F", "body.md", "--help"], in: scratch)
      #expect(help.termination == .exit(0))
    }
  }
}
