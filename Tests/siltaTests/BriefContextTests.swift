import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension BriefCommandTests {
  @Test func agentsPointerRequiresExistingFile() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["checkout", "-q", "api"], repo, scratch)
      for mode in [[], ["--short"], ["--json"], ["--hook"]] {
        let result = try run(mode, repo, scratch)
        #expect(!result.stdout.contains("AGENTS.md"))
      }
      try "Acme instructions\n".write(
        to: repo.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
      for mode in [[], ["--short"], ["--json"], ["--hook"]] {
        #expect(
          try run(mode, repo, scratch).stdout.contains("AGENTS.md: " + repo.path + "/AGENTS.md"))
      }
    }
  }

  @Test func appContextFollowsLocationAndTopicsExpandOnce() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      let result = try run(["--task", "AC-2", "--app", "api"], repo, scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("app: portal"))
      #expect(result.stdout.contains("summary: Acme API"))
      #expect(!result.stdout.contains("summary: Acme portal"))
      #expect(result.stdout.contains("environment: prod https://api.acme.example"))
      #expect(!result.stdout.contains("AGENTS.md:"))
      #expect(result.stdout.contains("description:\nAcme task body"))
      let data = try fixture.data(run(["--task", "AC-2", "--app", "api", "--json"], repo, scratch))
      let sections = try #require(data["sections"] as? [[String: String]])
      let ids = sections.compactMap { $0["id"] }
      #expect(
        ids == [
          "task", "plan", "description", "app", "app", "environments",
          "neighbours", "neighbours", "neighbours", "open_tasks", "open_tasks", "glossary",
        ])
      Golden.forTests().check(normalizeBrief(result.stdout, repo), "brief-context.txt")
      Golden.forTests().check(
        normalizeBrief(
          try run(["--task", "AC-2", "--app", "api", "--json"], repo, scratch).stdout, repo),
        "brief-context.json")
      let open = sections.filter { $0["id"] == "open_tasks" }.compactMap { $0["text"] }.joined()
      #expect(open.contains("AC-2"))
      #expect(!open.contains("AC-3"))
      #expect(open.components(separatedBy: "AC-2").count == 2)
      #expect(result.stdout.contains("glossary: messages = messaging, push"))
      #expect(result.stdout.contains("code show 'api' --lines 1 -- 'README.md'"))
      #expect(result.stdout.contains("next: silta --ws 'acme' ws show"))
      #expect(result.stdout.contains("service:push"))
      #expect(!result.stdout.contains("code ls 'api'"))
      let explicit = try run(
        ["--app", "api", "--topic", "PAYMENTS", "--topic", "payments"], repo, scratch)
      #expect(explicit.stdout.contains("AC-3"))
      #expect(explicit.stdout.contains("glossary: billing = payments"))
      #expect(!explicit.stdout.contains("open: AC-4"))
      let unknown = try run(["--topic", "absent", "--json"], repo, scratch)
      #expect(unknown.termination == .exit(2))
      #expect(unknown.stdout.contains("not_found"))
      #expect(unknown.stdout.contains("silta --ws 'acme' ws show"))
      #expect(try run(["--topic", "absent", "--hook"], repo, scratch).stdout.isEmpty)
    }
  }

  @Test func neighbourEvidenceUsesTheCommittedRefAndAppSubpath() throws {
    try withScratchDirectory { scratch in
      let repo = try committedEdgeFixture(scratch)
      let config = scratch.appending(path: "workspace.yml")
      try """
      workspace: {slug: acme, name: Acme, task_prefix: AC}
      repos: [{slug: platform}]
      apps:
        - {slug: api, repo: platform, ref: origin/api, subpath: guide}
        - {slug: portal, repo: platform, ref: origin/portal}
      edges:
        - from: portal
          to: api
          kind: calls
          summary: Acme integration
          code: ["api@acme-edge:Acme's guide.md", "api:Acme's guide.md"]
      """.write(to: config, atomically: true, encoding: .utf8)
      let edit = try SiltaBinary.run(
        [
          "--ws", "acme", "ws", "edit", "-F", config.path, "--approved", "Save Acme edges.",
          "--json",
        ],
        in: scratch, cwd: repo, environment: TaskCommandTests.actor)
      try #require(edit.termination == .exit(0), "\(edit.stdout)\(edit.stderr)")
      let warnings = try #require(
        try TaskStateCommandTests.object(edit)["warnings"] as? [[String: String]])
      let inspect = "silta --ws 'acme' ws show"
      let edgeWarnings = warnings.filter { $0["code"] == "edge_code_unavailable" }
      #expect(edgeWarnings.contains { $0["message"]?.contains("api:") == true })
      #expect(
        edgeWarnings.allSatisfy {
          $0["message"]?.hasSuffix("Inspect it with " + inspect + ".") == true
        })
      let brief = try run(["--app", "portal"], repo, scratch)
      try #require(brief.termination == .exit(0), "\(brief.stdout)\(brief.stderr)")
      let hints = brief.stdout.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("next: silta ") else { return nil }
        return String(line.dropFirst("next: ".count))
      }
      if let valid = hints.first(where: { $0.contains("code show 'api@acme-edge'") }) {
        let replay = try FirstWorkspaceCommandTests.replay(valid, in: scratch, cwd: repo)
        #expect(replay.termination == .exit(0) && replay.stdout.contains("Acme guide"))
      }
      let unknown = hints.contains { $0.contains("code show 'api'") }
      #expect(!unknown)
      let fallback = try #require(hints.first { $0 == inspect })
      let configRead = try FirstWorkspaceCommandTests.replay(fallback, in: scratch, cwd: repo)
      #expect(configRead.termination == .exit(0) && configRead.stdout.contains("Acme integration"))
    }
  }

  @Test func locallyAvailableEdgeReferencesMustBeSafeToPrint() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      let token = "ghp_" + String(repeating: "Q", count: 36)
      let names = ["Acme\u{2028}split.txt", token + ".txt"]
      for name in names {
        try Data("Acme guide\n".utf8).write(to: repo.appending(path: name))
      }
      try fixture.git(["add", "--"] + names, repo, scratch)
      try fixture.git(["commit", "-m", "Add Acme file names"], repo, scratch)
      let bytes = try JSONEncoder().encode(names.map { "api@api:" + $0 })
      let references = try #require(String(data: bytes, encoding: .utf8))
      try store(scratch).write {
        try $0.database.execute(
          sql: "UPDATE edge SET code_refs=? WHERE uid='out'", arguments: [references])
      }
      let report = try run(["--app", "api"], repo, scratch)
      #expect(report.termination == .exit(0))
      #expect(!report.stdout.contains(token) && !report.stdout.contains("split.txt"))
      #expect(!report.stdout.contains("next: silta --ws 'acme' code show"))
      #expect(report.stdout.contains("next: silta --ws 'acme' ws show"))
    }
  }

  private func committedEdgeFixture(_ scratch: URL) throws -> URL {
    let repo = try fixture.setup(scratch)
    try fixture.git(["checkout", "-q", "api"], repo, scratch)
    try fixture.git(["switch", "-c", "acme-edge"], repo, scratch)
    let directory = repo.appending(path: "guide")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("Acme guide\n".utf8).write(to: directory.appending(path: "Acme's guide.md"))
    try fixture.git(["add", "guide"], repo, scratch)
    try fixture.git(["commit", "-m", "Add Acme guide"], repo, scratch)
    return repo
  }

  @Test func backlogOrderLimitsVisibilityAndDoneResult() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write { tx in
        for seq in (5...30).reversed() {
          try tx.database.execute(
            sql: """
              INSERT INTO task(uid,workspace_id,seq,title,status,app_id,priority,
                result_md,done_sha,closed_at,created_by,created_at,updated_at)
              SELECT ?,1,?,'Acme backlog',?,id,?, 'First result\nSecond result',?, ?,
                'human:acme','','' FROM app WHERE slug='api'
              """,
            arguments: [
              "backlog-\(seq)", seq, seq <= 18 ? "todo" : "done",
              seq == 10 ? 1 : 2, String(repeating: "a", count: 40),
              seq == 30 ? "2023-11-14T10:00:00.000Z" : "2023-11-13T00:00:00.000Z",
            ])
        }
        try tx.database.execute(
          sql: """
            UPDATE task SET external_ref='ado:12' WHERE seq IN (5,29);
            UPDATE task SET archive_override='archived' WHERE seq IN (6,28);
            UPDATE task SET status='proposed' WHERE seq=7;
            UPDATE task SET status='proposed',created_by='agent:codex:acme' WHERE seq=8;
            UPDATE task SET closed_at='2020-01-01T00:00:00.000Z' WHERE seq=27;
            """)
      }
      let data = try fixture.data(run(["--app", "api", "--json"], repo, scratch))
      let sections = try #require(data["sections"] as? [[String: String]])
      func refs(_ id: String) -> [String] {
        sections.filter { $0["id"] == id }.compactMap {
          $0["text"]?.split(separator: " ").dropFirst().first.map(String.init)
        }
      }
      #expect(
        refs("open_tasks") == ["AC-10", "AC-1", "AC-2", "AC-8", "AC-9", "AC-11", "AC-12", "AC-13"])
      #expect(refs("recently_done") == ["AC-30", "AC-26", "AC-25", "AC-24", "AC-23"])
      let text = sections.filter { $0["id"] == "recently_done" }.compactMap { $0["text"] }.joined()
      #expect(text.contains("First result"))
      #expect(!text.contains("Second result"))
      #expect(text.contains(String(repeating: "a", count: 12)))
      #expect(!text.contains(String(repeating: "a", count: 13)))
      try settings("{\"archive_after_days\":null,\"proposals\":\"ask\"}", scratch)
      let tolerant = try run(["--app", "api", "--json"], repo, scratch)
      #expect(tolerant.termination == .exit(0))
      #expect(tolerant.stdout.contains("setting_unsupported"))
    }
  }

  @Test func contextBudgetsMaskDescriptionAndPreserveRetrySelections() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(
          sql: "UPDATE task SET description_md=? WHERE seq=2",
          arguments: ["Pwd=acme-secret\n" + String(repeating: "Acme 👩🏽‍💻é body ", count: 1000)])
      }
      for budget in [1, 200, 800, 2500] {
        let result = try run(
          ["--task", "AC-2", "--app", "api", "--topic", "billing", "--budget", String(budget)],
          repo, scratch)
        #expect(!result.stdout.contains("acme-secret"))
        #expect(!result.stdout.contains("\n\nmore:"))
        if budget >= 200 { #expect(result.stdout.count <= budget * 4) }
        if budget < 2500 {
          #expect(result.stdout.contains("brief --task AC-2 --app 'api' --topic 'billing'"))
        } else {
          #expect(!result.stdout.contains("brief --task"))
        }
      }
    }
  }

  func contextFixture(_ scratch: URL) throws -> URL {
    let repo = try fixture.setup(scratch)
    try fixture.git(["checkout", "-q", "api"], repo, scratch)
    try seedTasks(store(scratch))
    try store(scratch).write { tx in
      try tx.database.execute(
        sql: """
          UPDATE app SET summary=CASE slug
          WHEN 'api' THEN 'Acme API' ELSE 'Acme portal' END;
          UPDATE task SET description_md='Acme task body' WHERE seq=2;
          UPDATE task SET status='todo',app_id=NULL WHERE seq IN (3,4);
          INSERT INTO environment(uid,app_id,name,url)
          SELECT 'env',id,'prod','https://api.acme.example' FROM app WHERE slug='api';
          INSERT INTO service(id,uid,workspace_id,slug,name) VALUES(1,'service',1,'push','push');
          INSERT INTO edge(uid,workspace_id,from_app_id,to_app_id,kind,summary,code_refs)
            SELECT 'out',1,a.id,b.id,'calls','Acme integration','["api:README.md#L1"]'
            FROM app a,app b WHERE a.slug='api' AND b.slug='portal';
          INSERT INTO edge(uid,workspace_id,from_app_id,to_app_id,kind,summary)
            SELECT 'in',1,a.id,b.id,'calls','Acme caller'
          FROM app a,app b WHERE a.slug='portal' AND b.slug='api';
          INSERT INTO edge(uid,workspace_id,from_app_id,to_service_id,kind,summary)
            SELECT 'service-edge',1,id,1,'uses','Acme push' FROM app WHERE slug='api';
          INSERT INTO topic(id,uid,workspace_id,slug,name) VALUES
          (1,'messages',1,'messages','messages'),(2,'billing',1,'billing','billing');
          INSERT INTO topic_alias VALUES(1,1,'push'),(1,1,'messaging'),(1,2,'payments');
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,
          to_kind,to_id,created_by,created_at)
            SELECT 'topic-'||seq,1,'task',id,'about','topic',
            CASE WHEN seq=3 THEN 2 ELSE 1 END,'human:acme','' FROM task WHERE seq<=3;
          """)
    }
    try store(scratch).write {
      try $0.database.execute(
        sql: """
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,
          to_kind,to_id,created_by,created_at)
            SELECT 'topic-chain',1,'task',id,'about','topic',2,'human:acme',''
            FROM task WHERE seq=2
          """)
    }
    return repo
  }
}
