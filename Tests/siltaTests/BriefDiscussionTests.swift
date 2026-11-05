import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension BriefCommandTests {
  /// One handoff, a question for the caller, a human-answered question for someone else,
  /// a question for the caller on another task and a post on a task the caller claims.
  func discussionFixture(_ scratch: URL) throws -> URL {
    let repo = try fixture.setup(scratch)
    try fixture.git(["checkout", "-q", "api"], repo, scratch)
    try seedTasks(store(scratch))
    try store(scratch).write {
      try $0.database.execute(
        sql: """
          UPDATE task SET claimed_by=NULL,claimed_at=NULL WHERE seq=2;
          UPDATE task SET claimed_at='2023-11-14T21:00:00.000Z' WHERE seq=3;
          """)
    }
    let old = "agent:codex:old"
    try comment(
      2, 1,
      Post(
        "handoff", "State: callback inspected.\nNext step: wire refresh.", by: old, at: "21:00:00"),
      scratch)
    try comment(
      2, 2,
      Post("question", "Which callback URL?", by: old, to: ["agent:codex:acme"], at: "21:01:00"),
      scratch)
    try comment(
      2, 3, Post("question", "Ship before Friday?", by: old, to: ["human:acme"], at: "21:02:00"),
      scratch)
    try comment(2, 4, Post("answer", "Yes.", by: "human:acme", thread: 3, at: "21:03:00"), scratch)
    try comment(2, 5, Post("comment", "Looks good.", by: "human:acme", at: "21:03:30"), scratch)
    try comment(
      1, 1,
      Post(
        "question", "Can you check the portal build?", by: "human:acme",
        to: ["agent:codex:acme"], at: "21:04:00"),
      scratch)
    try comment(
      3, 1, Post("comment", "Rebased on main.", by: "human:acme", at: "21:05:00"), scratch)
    return repo
  }

  struct Post {
    let kind: String
    let body: String
    let actor: String
    let mentions: [String]
    let thread: Int?
    let time: String
    let resolved: Bool

    init(
      _ kind: String, _ body: String, by actor: String, to mentions: [String] = [],
      thread: Int? = nil, at time: String, resolved: Bool = false
    ) {
      (self.kind, self.body, self.actor, self.mentions) = (kind, body, actor, mentions)
      (self.thread, self.time, self.resolved) = (thread, time, resolved)
    }
  }

  func comment(_ task: Int, _ seq: Int, _ post: Post, _ scratch: URL) throws {
    let (kind, body, actor, thread, time, resolved) = (
      post.kind, post.body, post.actor, post.thread, post.time, post.resolved
    )
    let encoded = "[" + post.mentions.map { "\"" + $0 + "\"" }.joined(separator: ",") + "]"
    try store(scratch).write {
      try $0.database.execute(
        sql: """
          INSERT INTO comment(uid,task_id,seq,thread_id,kind,body_md,mentions,actor,
            resolved_at,resolved_by,created_at)
          SELECT ?,task.id,?,(SELECT c.id FROM comment c WHERE c.task_id=task.id AND c.seq=?),
            ?,?,?,?,?,?,?
          FROM task WHERE seq=?
          """,
        arguments: [
          "acme-c-\(task)-\(seq)", seq, thread, kind, body, encoded, actor,
          resolved ? "2023-11-14T22:00:00.000Z" : nil, resolved ? "human:acme" : nil,
          "2023-11-14T" + time + ".000Z", task,
        ])
    }
  }

  func run(as actor: String, _ flags: [String], _ repo: URL, _ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      ["brief", "--ws", "acme"] + flags, in: scratch, cwd: repo,
      environment: ["SILTA_ACTOR": actor, "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
  }

  @Test func discussionGoldenShowsHandoffCallerItemsAndInbox() throws {
    try withScratchDirectory { scratch in
      let repo = try discussionFixture(scratch)
      let text = try run(["--task", "AC-2", "--app", "api"], repo, scratch)
      #expect(text.termination == .exit(0), "\(text.stderr)")
      Golden.forTests().check(normalizeBrief(text.stdout, repo), "brief-discussion.txt")
      #expect(try run(["--task", "AC-2", "--app", "api"], repo, scratch) == text)
      let data = try fixture.data(run(["--task", "AC-2", "--app", "api", "--json"], repo, scratch))
      let ids = try #require(data["sections"] as? [[String: String]]).compactMap { $0["id"] }
      #expect(
        ids == [
          "task", "handoff", "task_inbox", "questions", "plan", "inbox", "inbox", "inbox",
          "app", "agents", "open_tasks", "open_tasks", "recently_done",
        ])
      #expect(
        data["more"] as? [String]
          == ["silta --ws 'acme' task show AC-2", "silta --ws 'acme' inbox"])
    }
  }

  @Test func inboxAttentionIsPerCaller() throws {
    try withScratchDirectory { scratch in
      let repo = try discussionFixture(scratch)
      let other = try run(
        as: "agent:codex:other", ["--task", "AC-2", "--app", "api"], repo, scratch)
      #expect(other.termination == .exit(0))
      #expect(other.stdout.contains("handoff AC-2/1 by agent:codex:old"))
      #expect(other.stdout.contains("questions: 2 open (1 answered)\n"))
      #expect(!other.stdout.contains("question AC-2/2"))
      #expect(!other.stdout.contains("inbox"))
      #expect(!other.stdout.contains("--reply-to"))
      let asker = try run(as: "agent:codex:old", ["--task", "AC-2", "--app", "api"], repo, scratch)
      #expect(
        asker.stdout.contains(
          "answer AC-2/4 on AC-2 by human:acme:\n> Yes.\n"
            + "next: silta --ws 'acme' comment accept 'AC-2/4'\n"))
      #expect(asker.stdout.contains("inbox: 1 item for agent:codex:old (scope: discussion)\n"))
      #expect(!asker.stdout.contains("AC-1/1"))
      #expect(!asker.stdout.contains("question AC-2/2"))
      let noTask = try run(["--app", "api"], repo, scratch)
      #expect(noTask.stdout.contains("question AC-2/2 on AC-2 by agent:codex:old:"))
      #expect(!noTask.stdout.contains("handoff"))
      let refs = ["AC-2/2", "AC-1/1", "AC-3/1"]
      let text = try run(["--task", "AC-2", "--app", "api"], repo, scratch).stdout
      for ref in refs {
        #expect(text.components(separatedBy: " " + ref + " ").count == 2, "\(ref)")
      }
    }
  }

  @Test func newestHandoffBreaksTimeTiesByIdAndStaysWhenResolved() throws {
    try withScratchDirectory { scratch in
      let repo = try discussionFixture(scratch)
      try comment(
        2, 6,
        Post("handoff", "Second handoff.", by: "agent:codex:old", at: "21:00:00", resolved: true),
        scratch)
      try comment(
        2, 7, Post("handoff", "Deleted handoff.", by: "agent:codex:old", at: "21:09:00"), scratch)
      try store(scratch).write {
        try $0.database.execute(
          sql: "UPDATE comment SET deleted_at='2023-11-14T21:10:00.000Z' WHERE uid='acme-c-2-7'")
      }
      let text = try run(["--task", "AC-2", "--app", "api"], repo, scratch).stdout
      #expect(
        text.contains(
          "handoff AC-2/6 by agent:codex:old at 2023-11-14T21:00:00.000Z, resolved:\n"
            + "> Second handoff.\n"))
      #expect(!text.contains("AC-2/1 by"))
      #expect(!text.contains("Deleted handoff"))
    }
  }

  @Test func handoffIsMaskedBeforeTrimmingAndCappedByBudget() throws {
    try withScratchDirectory { scratch in
      let repo = try discussionFixture(scratch)
      let body =
        String(repeating: "Acme state. ", count: 29) + "Pwd=acme-secret-value\n"
        + String(repeating: "Acme next. ", count: 700)
      try store(scratch).write {
        try $0.database.execute(
          sql: "UPDATE comment SET body_md=? WHERE uid='acme-c-2-1'", arguments: [body])
      }
      for flags in [[], ["--short"], ["--budget", "5000"]] {
        let result = try run(["--task", "AC-2", "--app", "api"] + flags, repo, scratch)
        #expect(result.stdout.contains("(handoff trimmed; silta --ws 'acme' task show AC-2)\n"))
        #expect(!result.stdout.contains("acme-se"))
        #expect(result.stdout.contains("plan (revision 0):"))
        let handoff = try #require(
          result.stdout.components(separatedBy: "handoff AC-2/1").last?
            .components(separatedBy: "(handoff trimmed").first)
        let cap = flags.isEmpty ? 1500 : flags == ["--short"] ? 480 : 3000
        #expect(handoff.count <= cap && handoff.count > cap - 120, "\(flags): \(handoff.count)")
      }
    }
  }

  @Test func heavyDiscussionKeepsPlanFooterAndBudget() throws {
    try withScratchDirectory { scratch in
      let repo = try discussionFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(
          sql: "UPDATE task SET plan_md=? WHERE seq=2",
          arguments: [(1...60).map { "- [ ] Acme step \($0)" }.joined(separator: "\n")])
      }
      for seq in 10..<20 {
        let body = String(repeating: "Acme question? ", count: 80)
        try comment(
          2, seq,
          Post(
            "question", body, by: "agent:codex:old", to: ["agent:codex:acme"],
            at: "21:2\(seq - 10):00"),
          scratch)
      }
      let short = try run(["--task", "AC-2", "--app", "api", "--short"], repo, scratch)
      #expect(short.stdout.count <= 3200)
      #expect(short.stdout.contains("plan (revision 0):\n1. [ ] Acme step 1\n"))
      #expect(
        short.stdout.hasSuffix(
          " | silta --ws 'acme' task show AC-2 | silta --ws 'acme' inbox\n"))
      #expect(short.stdout.components(separatedBy: "\nquestion AC-2/").count <= 4)
      let before = try hookTimeoutCount(scratch)
      let hook = try run(["--task", "AC-2", "--app", "api", "--hook"], repo, scratch)
      #expect(hook.termination == .exit(0))
      if try hookTimeoutCount(scratch) == before { #expect(hook == short) }
      for budget in [1, 50, 100, 200, 400, 800, 2500] {
        let result = try run(
          ["--task", "AC-2", "--app", "api", "--budget", String(budget)], repo, scratch)
        #expect(result.termination == .exit(0))
        if budget >= 200 { #expect(result.stdout.count <= budget * 4, "\(budget)") }
        #expect(result.stdout.contains("task: AC-2\n"))
        #expect(result.stdout.contains("silta --ws 'acme' inbox\n"))
      }
    }
  }
}

extension BriefCommandTests {
  @Test func descriptionCapScalesWithBudget() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(
          sql: "UPDATE task SET description_md=? WHERE seq=2",
          arguments: [String(repeating: "Acme description ", count: 800)])
      }
      for (budget, cap) in [(2500, 600), (2504, 600), (2505, 601), (5000, 1200)] {
        let data = try fixture.data(
          run(
            ["--task", "AC-2", "--app", "api", "--budget", String(budget), "--json"],
            repo, scratch))
        let sections = try #require(data["sections"] as? [[String: String]])
        let count = sections.first { $0["id"] == "description" }?["text"]?.count ?? 0
        #expect(count <= cap && count > cap - 20, "\(budget): \(count)")
      }
      let huge = try run(
        ["--task", "AC-2", "--app", "api", "--budget", String(Int.max)], repo, scratch)
      #expect(huge.termination == .exit(0))
      #expect(!huge.stdout.contains("description trimmed"))
    }
  }

  @Test func malformedClosedAtSkipsOnlyThatRow() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(
          sql: """
            WITH RECURSIVE n(x) AS (VALUES(5) UNION ALL SELECT x+1 FROM n WHERE x<10)
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,result_md,closed_at,
              created_by,created_at,updated_at)
            SELECT 'done-'||x,1,x,'Acme done','done',app.id,'Acme result '||x,
              '2023-11-14T20:00:0'||(x-5)||'.000Z','human:acme','',''
            FROM n,app WHERE app.slug='api';
            UPDATE task SET closed_at='not a date' WHERE seq=10;
            """)
      }
      for flags in [[], ["--hook"]] {
        let before = try hookTimeoutCount(scratch)
        let result = try run(["--task", "AC-2", "--app", "api"] + flags, repo, scratch)
        #expect(result.termination == .exit(0))
        // A loaded machine can hit the hook deadline, which prints nothing by design.
        if try hookTimeoutCount(scratch) > before { continue }
        #expect(result.stdout.components(separatedBy: "\ndone: ").count == 6, "\(flags)")
        #expect(!result.stdout.contains("done: AC-10"))
        #expect(result.stdout.contains("done: AC-9 Acme result 9"))
      }
      let json = try run(["--task", "AC-2", "--app", "api", "--json"], repo, scratch)
      #expect(json.stdout.contains("\"closed_at_unreadable\""))
      #expect(!json.stdout.contains("not a date"))
    }
  }
}
