import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension BriefCommandTests {
  @Test func descriptionCapKeepsLaterContext() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(sql: "UPDATE task SET description_md=? WHERE seq=2",
          arguments: [String(repeating: "Acme description ", count: 800)])
      }
      for mode in [[], ["--short"]] {
        let result = try run(["--task", "AC-2", "--app", "api"] + mode, repo, scratch)
        withKnownIssue("#16: Long description must preserve rich context") {
          #expect(result.stdout.contains("app: api\n"))
          #expect(result.stdout.contains("AGENTS.md:"))
          #expect(result.stdout.contains("neighbour:"))
          #expect(result.stdout.contains("open: AC-1"))
          #expect(result.stdout.contains("description trimmed; silta --ws 'acme' task show AC-2"))
        }
      }
    }
  }

  @Test func explicitTopicSurvivesCrowdingAndHasCompleteOmissionCommands() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(sql: """
          WITH RECURSIVE n(x) AS (VALUES(5) UNION ALL SELECT x+1 FROM n WHERE x<16)
          INSERT INTO task(uid,workspace_id,seq,title,status,app_id,created_by,created_at,updated_at)
          SELECT 'crowd-'||x,1,x,'Acme crowd','todo',app.id,'human:acme','',''
          FROM n,app WHERE app.slug='api';
          UPDATE task SET seq=100 WHERE seq=3;
          """)
      }
      let result = try run(["--app", "api", "--topic", "PAYMENTS"], repo, scratch)
      withKnownIssue("#16: Explicit topics must survive app backlog limits") {
        #expect(result.stdout.contains("open: AC-100"))
        #expect(result.stdout.contains("more open;"))
        #expect(result.stdout.contains("task ls --app 'api'"))
        #expect(result.stdout.contains("task ls --topic 'billing'"))
      }
    }
  }

  @Test func settingsHintIsVisibleBoundedAndMasked() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try settings("{\"proposals\":\"maybe\",\"future\":{\"secret\":\"acme-hidden\",\"api_token\":\"acme-hidden\"},\"review_gate\":\"" + String(repeating: "x", count: 400) + "\"}", scratch)
      let result = try run([], repo, scratch)
      withKnownIssue("#16: Unsupported settings need a bounded visible human hint") {
        #expect(result.stdout.contains("settings unsupported: proposals"))
        #expect(result.stdout.contains("ask the human"))
        #expect(!result.stderr.contains("acme-hidden"))
        #expect(result.stderr.split(separator: "\n").allSatisfy { $0.count < 340 })
      }
    }
  }

  @Test func compactOutputsKeepValidMixedCodeRefsAndDiskCase() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(sql: """
          UPDATE edge SET code_refs='[7,"api:README.md#L1"]' WHERE uid='out';
          UPDATE task SET result_md='',done_sha=NULL,status='done',app_id=(
            SELECT id FROM app WHERE slug='api') WHERE seq=4;
          """)
      }
      let result = try run(["--task", "AC-2", "--app", "api"], repo, scratch)
      withKnownIssue("#16: Compact rows and independent code refs") {
        #expect(result.stdout.contains("code show 'api' 'README.md' --lines 1"))
        #expect(!result.stdout.contains("code ls 'api'"))
        #expect(result.stdout.contains("open: AC-2 [doing, p2] Acme task (app: portal)"))
        #expect(result.stdout.contains("done: AC-4\n"))
        #expect(result.stdout.contains("AGENTS.md: " + repo.path + "/AGENTS.md"))
      }
    }
  }

  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func hookWithTwentyThousandTasks() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(sql: """
          WITH RECURSIVE n(x) AS (VALUES(5) UNION ALL SELECT x+1 FROM n WHERE x<20004)
          INSERT INTO task(uid,workspace_id,seq,title,status,app_id,description_md,plan_md,
            result_md,created_by,created_at,updated_at)
          SELECT 'bulk-'||x,1,x,'Acme backlog','todo',app.id,?,?,?,'human:acme','',''
          FROM n,app WHERE app.slug='api'
          """, arguments: StatementArguments(Array(repeating: String(repeating: "Acme unused ", count: 180), count: 3)))
      }
      let short = try run(["--task", "AC-2", "--app", "api", "--short"], repo, scratch)
      #expect(short.stdout.contains("open: AC-1"))
      let hook = try run(["--task", "AC-2", "--app", "api", "--hook"], repo, scratch)
      let warnings = try DogfoodLogTests.last(scratch)["warnings"] as? [String] ?? []
      withKnownIssue("#16: Hook must retain context with a large workspace") {
        #expect(hook.stdout.contains("open: AC-1"))
        #expect(!warnings.contains("hook_timeout"))
      }
    }
  }
}

extension BriefCommandTests {
  @Test func productionCandidatesPreservePlacementSelectionsAndBudget() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try fixture.git(["checkout", "-q", "from-non-app"], repo, scratch)
      try store(scratch).write {
        try $0.database.execute(sql: "UPDATE task SET app_id=NULL,plan_md='' WHERE seq=4")
      }
      for budget in [1, 200, 800] {
        let result = try run(["--task", "AC-4", "--topic", "PAYMENTS", "--budget", String(budget)], repo, scratch)
        if budget >= 200 { #expect(result.stdout.count <= budget * 4) }
        if let candidates = result.stdout.range(of: "candidates:") {
          let task = try #require(result.stdout.range(of: "task: AC-4"))
          #expect(candidates.lowerBound < task.lowerBound)
          #expect(result.stdout.contains("brief --app 'api' --task AC-4 --topic 'PAYMENTS'"))
          #expect(result.stdout.contains("brief --app 'portal' --task AC-4 --topic 'PAYMENTS'"))
        }
        if budget == 800 { #expect(result.stdout.contains("candidates:")) }
        let data = try fixture.data(run(["--task", "AC-4", "--topic", "PAYMENTS", "--budget", String(budget), "--json"], repo, scratch))
        let sections = try #require(data["sections"] as? [[String: String]])
        if budget == 800 { #expect(sections.first?["id"] == "candidates") }
      }
    }
  }

  @Test func backlogVisibilityAndNeighbourTies() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(sql: """
          UPDATE task SET status='blocked',plan_md='' WHERE seq=1;
          UPDATE task SET status='done',app_id=(SELECT id FROM app WHERE slug='api'),
            closed_at='2020-01-01T00:00:00.000Z' WHERE seq=4;
          INSERT INTO edge(uid,workspace_id,from_app_id,to_app_id,kind,summary)
          SELECT 'tie-z',1,a.id,b.id,'zzz','Acme tie z' FROM app a,app b
          WHERE a.slug='portal' AND b.slug='api';
          INSERT INTO edge(uid,workspace_id,from_app_id,to_app_id,kind,summary)
          SELECT 'tie-a',1,a.id,b.id,'aaa','Acme tie first' FROM app a,app b
          WHERE a.slug='portal' AND b.slug='api';
          INSERT INTO edge(uid,workspace_id,from_app_id,to_app_id,kind,summary)
          SELECT 'tie-b',1,a.id,b.id,'aaa','Acme tie second' FROM app a,app b
          WHERE a.slug='portal' AND b.slug='api';
          """)
      }
      let result = try run(["--app", "api"], repo, scratch)
      #expect(result.stdout.contains("open: AC-1 [blocked"))
      #expect(!result.stdout.contains("done: AC-4"))
      let first = try #require(result.stdout.range(of: "Acme tie first"))
      let second = try #require(result.stdout.range(of: "Acme tie second"))
      let last = try #require(result.stdout.range(of: "Acme tie z"))
      #expect(first.lowerBound < second.lowerBound && second.lowerBound < last.lowerBound)
    }
  }
}

extension BriefCommandTests {
  @Test func excerptPrefixesAndMarkers() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(sql: "UPDATE task SET description_md=? WHERE seq=2",
          arguments: [String(repeating: "AcmeDescriptionPrefix ", count: 100)])
      }
      let description = try run(["--task", "AC-2", "--app", "api", "--budget", "200"], repo, scratch)
      #expect(description.stdout.contains("description:\nAcmeDescriptionPrefix"))
      withKnownIssue("#16: Description recovery must survive partial global trimming") {
        #expect(description.stdout.contains("(description trimmed; silta --ws 'acme' task show AC-2)"))
      }
      try store(scratch).write {
        try $0.database.execute(sql: "UPDATE task SET description_md='' WHERE seq=2")
        try $0.database.execute(sql: "UPDATE app SET summary=? WHERE slug='api'",
          arguments: [String(repeating: "AcmeSummaryPrefix ", count: 100)])
      }
      let summary = try fixture.data(run(["--task", "AC-2", "--app", "api", "--budget", "200", "--json"], repo, scratch))
      let sections = try #require(summary["sections"] as? [[String: String]])
      let text = sections.filter { $0["id"] == "app" }.compactMap { $0["text"] }.joined()
      #expect(text.contains("summary: AcmeSummaryPrefix"))
      #expect(text.contains("…\n"))
    }
  }
}
