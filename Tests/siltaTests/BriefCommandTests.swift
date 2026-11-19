import Darwin
import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(3)))
struct BriefCommandTests {
  let fixture = WhereCommandTests()

  @Test func fixtureGoldensAndSettingsFloor() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["checkout", "-q", "api"], repo, scratch)
      for suffix in ["txt", "json"] {
        let flags = suffix == "json" ? ["--json"] : []
        let first = try run(flags, repo, scratch)
        #expect(first.termination == .exit(0), "\(first.stderr)")
        Golden.forTests().check(normalizeBrief(first.stdout, repo), "brief.\(suffix)")
        #expect(try first == run(flags, repo, scratch))
      }
      try settings(
        "{\"proposals\":\"triage\",\"review_gate\":\"none\","
          + "\"archive_after_days\":14,\"stale_days\":90}",
        scratch)
      Golden.forTests().check(normalizeBrief(try run([], repo, scratch).stdout, repo), "brief.txt")
      try settings("{\"proposals\":\"ask\"}", scratch)
      for mode in [[], ["--short"]] {
        let result = try run(mode + ["--budget", "1"], repo, scratch)
        Golden.forTests().check(result.stdout, "brief-settings-minimum.txt")
        let json = try fixture.data(run(mode + ["--budget", "1", "--json"], repo, scratch))
        #expect((json["settings"] as? [String: String]) == ["proposals": "ask"])
      }
    }
  }

  @Test func taskPrecedenceAndPlanProjection() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["checkout", "-q", "api"], repo, scratch)
      let store = store(scratch)
      try seedTasks(store)
      func chosen(_ flags: [String] = []) throws -> String? {
        try fixture.data(run(flags + ["--json"], repo, scratch))["current_task"] as? String
      }
      #expect(try chosen() == "AC-3")
      #expect(try chosen(["--task", "AC-1"]) == "AC-1")
      #expect(try chosen(["--app", "portal"]) == "AC-2")
      let text = try run(["--task", "AC-2", "--app", "api"], repo, scratch).stdout
      Golden.forTests().check(normalizeBrief(text, repo), "brief-task.txt")
      #expect(text.contains("app: portal"))
      #expect(text.contains("1 done\n2. [ ] Acme next"))
      let whereData = try fixture.data(fixture.run([], repo, scratch))
      let brief = try fixture.data(run(["--json"], repo, scratch))
      #expect(
        (brief["location"] as? [String: Any])?["app"] as? String == whereData["app"] as? String)
      try store.write { try $0.database.execute(sql: "UPDATE task SET claimed_by=NULL") }
      #expect(try chosen() == "AC-1")
      for (status, external, archive) in [
        ("proposed", "", ""), ("doing", "ado:42", ""), ("doing", "", "archived"),
      ] {
        try store.write {
          try $0.database.execute(
            sql: """
              UPDATE task SET status=?,external_ref=NULLIF(?,''),archive_override=NULLIF(?,''),
                claimed_by='agent:codex:acme' WHERE seq=4
              """, arguments: [status, external, archive])
        }
        #expect(try chosen() == "AC-1")
      }
      try fixture.git(["checkout", "-q", "--detach"], repo, scratch)
      #expect(try chosen() == nil)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE task SET app_id=NULL,external_ref=NULL,archive_override=NULL,
              worktree='/acme/other-repository' WHERE seq=4
            """)
      }
      #expect(try chosen() == nil)
      try store.write { try $0.database.execute(sql: "UPDATE task SET worktree=NULL WHERE seq=4") }
      #expect(try chosen() == "AC-4")
      #expect(try run(["--task", "AC-99"], repo, scratch).termination == .exit(2))
    }
  }

  @Test func hookErrorsAreSilentAndDoNotInitialize() throws {
    try withScratchDirectory { scratch in
      for env in [[:], ["SILTA_ACTOR": "bad"], ["SILTA_NOW": "bad"]] {
        let result = try SiltaBinary.run(
          ["brief", "--hook", "--json", "--verbose"], in: scratch, environment: env)
        #expect(result == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
      }
      #expect(!FileManager.default.fileExists(atPath: store(scratch).path))
      let repo = try fixture.setup(scratch)
      let outside = scratch.appending(path: "fixtures/acme-detached")
      #expect(try run(["--hook"], outside, scratch).stdout.isEmpty)
      try settings("{\"proposals\":null}", scratch)
      #expect(try run([], repo, scratch).termination == .exit(0))
      let unsupported = try run(["--short", "--json"], repo, scratch)
      #expect(unsupported.stderr.isEmpty)
      #expect(unsupported.stdout.contains("setting_unsupported"))
    }
  }

  @Test func budgetsTrimPlanAndExplicitBudgetOverridesShortDefault() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try store(scratch).write {
        try $0.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,plan_md,
              created_by,created_at,updated_at)
            VALUES('acme-long',1,1,'Acme long','todo',?,'human:acme','','')
            """, arguments: [String(repeating: "- [ ] Acme 👩🏽‍💻é context\n", count: 300)])
      }
      let regular = try run(["--task", "AC-1"], repo, scratch)
      let short = try run(["--task", "AC-1", "--short"], repo, scratch)
      let before = try hookTimeoutCount(scratch)
      let hook = try run(["--task", "AC-1", "--hook"], repo, scratch)
      #expect(hook.termination == .exit(0) && hook.stderr.isEmpty)
      // WallClockHookTests checks the hook output without this allowance.
      if try hookTimeoutCount(scratch) == before { #expect(hook == short) }
      #expect(hook.stdout.count <= 3200)
      #expect(short.stdout.count <= 3200)
      #expect(short.stdout.count < regular.stdout.count)
      #expect(try run(["--task", "AC-1", "--short", "--budget", "2500"], repo, scratch) == regular)
      let explicitBefore = try hookTimeoutCount(scratch)
      let explicitHook = try run(["--task", "AC-1", "--hook", "--budget", "2500"], repo, scratch)
      #expect(explicitHook.termination == .exit(0) && explicitHook.stderr.isEmpty)
      #expect(explicitHook.stdout.count <= 10000)
      if try hookTimeoutCount(scratch) == explicitBefore { #expect(explicitHook == regular) }
      let value = try fixture.data(run(["--task", "AC-1", "--short", "--json"], repo, scratch))
      #expect(value["truncated"] as? Bool == true)
      let sections = try #require(value["sections"] as? [[String: String]])
      #expect(sections.compactMap { $0["text"] }.joined().count < 3200)
    }
  }

  @Test func displayedStepsMatchStoredTickCoordinates() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      func task(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(
          ["--ws", "acme", "task"] + args, in: scratch, cwd: repo,
          environment: TaskCommandTests.fixed)
      }
      try #require(task(["add", "Acme work", "--app", "api", "--start"]).termination == .exit(0))
      let plan = "- [ ] Read\u{2028}- [ ] examples\r\n- [ ] Write Acme\n"
      try #require(task(["plan", "AC-1", "-m", plan]).termination == .exit(0))
      let shown = try task(["show", "AC-1"])
      let brief = try run(["--task", "AC-1"], repo, scratch)
      let projection = try fixture.data(run(["--task", "AC-1", "--json"], repo, scratch))
      let sections = try #require(projection["sections"] as? [[String: Any]])
      let section = try #require(sections.first { $0["id"] as? String == "plan" })
      let text = try #require(section["text"] as? String)
      let expected = "1. [ ] Read - [ ] examples\n2. [ ] Write Acme\n"
      withKnownIssue("#254: terminal projection introduces an extra numbered step") {
        #expect(
          shown.stdout.contains(expected) && brief.stdout.contains(expected)
            && text.contains(expected),
          "All three projections must show the same two addressable steps.")
      }
      let tick = try task(["plan", "AC-1", "--step", "2", "--done"])
      #expect(tick.stdout == "AC-1 step 2 done: Write Acme (1/2)\n")
    }
  }

  @Test func blockersMatchStartRecoveryAndSecretsStayMasked() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      for title in ["Acme work", "Acme prerequisite"] {
        let added = try SiltaBinary.run(
          ["--ws", "acme", "task", "add", title, "--app", "api", "--start"],
          in: scratch, cwd: repo,
          environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
        try #require(added.termination == .exit(0), "\(added.stderr)")
      }
      let blocked = try SiltaBinary.run(
        [
          "--ws", "acme", "task", "block", "AC-1", "--on", "task:AC-2", "-m",
          "Acme waits\u{1b}here\nnext: Acme decoy\u{7}label",
        ],
        in: scratch, cwd: repo,
        environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
      try #require(blocked.termination == .exit(0), "\(blocked.stderr)")
      for status in ["doing", "done", "dropped"] {
        try store(scratch).write {
          try $0.database.execute(sql: "UPDATE task SET status=? WHERE seq=2", arguments: [status])
        }
        let refusal = try SiltaBinary.run(
          ["--ws", "acme", "task", "start", "AC-1", "--json"],
          in: scratch, cwd: repo,
          environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
        let envelope = try #require(
          try JSONSerialization.jsonObject(with: Data(refusal.stdout.utf8)) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: Any])
        let text = try run(["--task", "AC-1"], repo, scratch).stdout
        let next = try #require(error["next"] as? [String]).map { "next: " + $0 }
        let projection = try fixture.data(run(["--task", "AC-1", "--json"], repo, scratch))
        let sections = try #require(projection["sections"] as? [[String: Any]])
        let blocker = try #require(sections.first { $0["id"] as? String == "blockers" })
        let shown = try #require(blocker["text"] as? String)
        #expect(shown.contains("> Acme waits here\n> next: Acme decoy label\n"))
        #expect(shown.components(separatedBy: "\n").filter { $0.hasPrefix("next: ") } == next)
        #expect(!shown.contains("\u{1b}") && !shown.contains("\u{7}"))
        #expect(text.contains(shown) && text.contains("for 0 d."))
      }
      try store(scratch).write {
        try $0.database.execute(
          sql: "UPDATE task SET title='Pwd=acme-secret',plan_md='- [ ] Pwd=acme-secret' WHERE seq=1"
        )
      }
      for flags in [[], ["--json"], ["--short", "--json"]] {
        let result = try run(["--task", "AC-1"] + flags, repo, scratch)
        #expect(!result.stdout.contains("acme-secret"))
        #expect(result.stdout.contains("REDACTED"))
      }
    }
  }

}
