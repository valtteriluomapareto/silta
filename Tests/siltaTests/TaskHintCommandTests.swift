import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct TaskHintCommandTests {
  @Test func writesOfferOnlyActionableRecipesAndConsumeTheHintOnce() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      try add(2, in: scratch)
      _ = try ok(["task", "done", "AC-2", "-m", "Finished the Acme dependency."], in: scratch)
      let proposed = try ok(["task", "add", "Follow AC-1 and AC-2"], in: scratch)
      let prompts = try hints(proposed)
      #expect(prompts.count == 2)
      #expect(prompts.allSatisfy { $0.contains("task link 'AC-3'") && !$0.contains("task block") })
      let started = try ok(["task", "add", "Follow AC-1 and AC-2", "--start"], in: scratch)
      let actionable = try hints(started)
      #expect(actionable.count == 2)
      #expect(actionable.first?.contains("task block 'AC-4' --on 'task:AC-1' -F -") == true)
      #expect(actionable.last?.contains("task block") == false)
      let repeated = try ok(["comment", "AC-4", "-m", "Waiting for AC-1."], in: scratch)
      #expect(try hints(repeated).isEmpty)
      let plan = try ok(["task", "plan", "AC-1", "-m", "- [ ] Review task:AC-2"], in: scratch)
      #expect(try hints(plan).first?.contains("task link 'AC-1'") == true)
      let show = try ok(["task", "show", "AC-1", "--timeline"], in: scratch)
      #expect(!show.stdout.contains("hinted task"))
    }
  }

  @Test func relationshipsAndForeignClaimSuppressMutationHints() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      try add(6, in: scratch)
      _ = try ok(["task", "add", "Acme subtask", "--parent", "AC-1", "--start"], in: scratch)
      _ = try ok(["task", "link", "AC-7", "AC-2", "--rel", "relates"], in: scratch)
      _ = try ok(["task", "link", "AC-3", "AC-7"], in: scratch)
      _ = try ok(["task", "block", "AC-4", "--on", "AC-7", "-m", "Waiting."], in: scratch)
      _ = try ok(["task", "add", "Acme child", "--parent", "AC-7", "--start"], in: scratch)
      let body = ["comment", "AC-7", "-m", "AC-1 AC-2 AC-3 AC-4 AC-6 AC-8"]
      let foreign = try ok(body, in: scratch, actor: "agent:codex:other")
      #expect(try hints(foreign).isEmpty)
      let own = try ok(body, in: scratch)
      let scoped = try hints(own)
      #expect(scoped.count == 1)
      #expect(scoped.first?.contains("task link 'AC-7' 'task:AC-6'") == true)
      let reverse = try ok(["comment", "AC-6", "-m", "Coordinate with AC-7."], in: scratch)
      #expect(try hints(reverse).count == 1)
    }
  }

  @Test func handoffsIgnoreQuotedAndCodeExamplesAndCapWarnings() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      try add(9, in: scratch)
      let body = """
        > Prior handoff named AC-1.
        ```sh
        echo AC-2
        ```
            AC-3
        See https://example.invalid/AC-4 and ZZ-5.
        Coordinate with `task:AC-5`, AC-6, AC-5, AC-7, AC-8 and AC-9.
        """
      let handoff = try ok(["comment", "AC-9", "--kind", "handoff", "-m", body], in: scratch)
      let first = try hints(handoff)
      #expect(first.count == 3)
      for (hint, ref) in zip(first, ["AC-5", "AC-6", "AC-7"]) {
        #expect(hint.contains("task link 'AC-9' 'task:\(ref)'"))
      }
      let repeatHandoff = try ok(["comment", "AC-9", "-m", body], in: scratch)
      #expect(try hints(repeatHandoff).first?.contains("'task:AC-8'") == true)
      let again = try ok(["comment", "AC-9", "-m", body], in: scratch)
      #expect(try hints(again).isEmpty)
    }
  }

  @Test func lastCheckboxHintsWithoutChangingTheTaskOrRevision() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      try add(1, in: scratch)
      let plan = "- [ ] First\n- [ ] Last\n\n```\n- [ ] Example\n```"
      _ = try ok(["task", "plan", "AC-1", "-m", plan], in: scratch)
      var checked = [Bool]()
      for (step, flag) in [
        (1, "--done"), (2, "--done"), (2, "--done"), (2, "--undo"), (2, "--done"),
      ] {
        let result = try ok(
          ["task", "plan", "AC-1", "--step", String(step), flag, "--if-rev", "1"], in: scratch)
        let warning = try warnings(result, code: "plan_complete")
        checked.append(!warning.isEmpty)
        if let first = warning.first {
          #expect(first.contains("silta --ws 'acme' task submit 'AC-1'"))
          #expect(first.contains("task plan 'AC-1' --if-rev 1 -F -"))
          #expect(first.contains("complete"))
        }
      }
      #expect(checked == [false, true, false, false, true])
      let shown = try ok(["task", "show", "AC-1"], in: scratch)
      let data = try TaskStateCommandTests.data(shown)
      #expect(data["status"] as? String == "doing" && data["plan_rev"] as? Int == 1)
    }
  }

  private func add(_ count: Int, in scratch: URL) throws {
    for i in 1...count { _ = try ok(["task", "add", "Acme task \(i)", "--start"], in: scratch) }
  }

  private func ok(
    _ args: [String], in scratch: URL, actor: String = "agent:codex:acme"
  ) throws -> CLIResult {
    let cli = try SiltaBinary.run(
      args + ["--deterministic", "--json"], in: scratch,
      environment: TaskCommandTests.fixed.merging(["SILTA_ACTOR": actor]) { $1 })
    try #require(cli.termination == .exit(0), "\(cli.stdout)\(cli.stderr)")
    return cli
  }

  private func hints(_ result: CLIResult) throws -> [String] {
    try warnings(result, code: "task_ref_unlinked")
  }

  private func warnings(_ result: CLIResult, code: String) throws -> [String] {
    let root = try GuideContractTests.object(result.stdout)
    let values = try #require(root["warnings"] as? [[String: String]])
    return values.filter { $0["code"] == code }.compactMap { $0["message"] }
  }
}

extension TaskHintCommandTests {
  @Test func retainedSecretContentsAreNotTreatedAsTaskReferences() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      try add(3, in: scratch)
      let result = try ok(
        [
          "comment", "AC-1", "--allow-secret", "--approved", "Keep Acme's fixture text.",
          "-m", "Pwd=AC-2\nCoordinate with AC-3.",
        ], in: scratch)
      let warnings = try hints(result)
      #expect(warnings.count == 1)
      #expect(warnings.first?.contains("'task:AC-3'") == true)
    }
  }

  @Test func editReadsOnlyChangedFields() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try add(3, in: scratch)
      try store.write {
        try $0.database.execute(sql: "UPDATE task SET acceptance_md='Check AC-2' WHERE seq=1")
      }
      let file = scratch.appending(path: "edit.md")
      let printed = try ok(["task", "edit", "AC-1", "--print"], in: scratch)
      let data = try TaskStateCommandTests.data(printed)
      let current = try #require(data["document"] as? String)
      let document = current.replacingOccurrences(of: "Acme task 1", with: "Coordinate with AC-3")
      try document.write(to: file, atomically: true, encoding: .utf8)
      let result = try ok(["task", "edit", "AC-1", "-F", file.path], in: scratch)
      let actual = try hints(result)
      #expect(actual.count == 1)
      #expect(actual.first?.contains("'task:AC-3'") == true)
    }
  }

  @Test func undeliveredAndFailedAdvisoriesDoNotConsumeTheMarker() async throws {
    try await withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try add(3, in: scratch)
      let environment = try await SiltaEnvironment.system(
        environment: TaskCommandTests.fixed.merging([
          "SILTA_HOME": scratch.appending(path: "silta-home").path
        ]) { $1 }, deterministic: true)
      let muted = try TaskService(environment: environment, workspace: "acme")
        .comment("AC-1", CommentDraft(body: "AC-2"))
      #expect(muted.warnings.isEmpty)
      try store.write {
        try $0.database.execute(
          sql: """
            CREATE TRIGGER refuse_advisory BEFORE INSERT ON task_event
            WHEN new.kind='field'
              AND new.body='hinted task ' || (SELECT uid FROM task WHERE seq=3)
            BEGIN SELECT RAISE(ABORT,'Acme injected advisory failure'); END;
            """)
      }
      let command = ["comment", "AC-1", "-m", "Check AC-2 and AC-3."]
      let isolated = try ok(command, in: scratch)
      #expect(try hints(isolated).isEmpty)
      let count = try store.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM comment") }
      #expect(count == 2)
      try store.write { try $0.database.execute(sql: "DROP TRIGGER refuse_advisory") }
      let retried = try ok(command, in: scratch)
      #expect(try hints(retried).count == 2)
    }
  }

  @Test func writtenHintSurvivesExportRestoreAndAnActorChange() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      try add(2, in: scratch)
      let mention = ["comment", "AC-1", "-m", "Check AC-2."]
      #expect(try hints(ok(mention, in: scratch)).count == 1)
      _ = try ok(["task", "submit", "AC-1"], in: scratch)
      let root = scratch.appending(path: "out")
      _ = try ok(["export", "--to", root.path], in: scratch)
      try withScratchDirectory { restored in
        _ = try ok(
          [
            "restore", root.appending(path: "acme").path, "--approved",
            "Restore Acme's exported workspace.",
          ], in: restored)
        _ = try ok(["ws", "use", "acme"], in: restored)
        let task = try ok(["task", "show", "AC-1"], in: restored)
        #expect(try TaskStateCommandTests.data(task)["claimed_by"] == nil)
        let repeated = try ok(mention, in: restored, actor: "agent:codex:other")
        #expect(try hints(repeated).isEmpty)
      }
    }
  }
}
