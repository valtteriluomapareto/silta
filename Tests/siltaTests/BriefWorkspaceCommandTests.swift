import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct BriefWorkspaceCommandTests {
  private let fixture = BriefCommandTests()

  @Test(arguments: [false, true])
  func workspaceBriefOutsideGit(explicit: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try fixture.fixture.setup(scratch)
      let store = fixture.store(scratch)
      try fixture.seedTasks(store)
      if explicit {
        try store.write {
          try $0.database.execute(
            sql: """
              INSERT INTO workspace(uid,slug,name,task_prefix)
              VALUES('beta','beta','Acme Beta','BE');
              UPDATE meta SET value='beta' WHERE key='current_workspace';
              """)
        }
      }
      let args = explicit ? ["--ws", "acme"] : []
      let result = try run(args, scratch: scratch)
      let data = try fixture.fixture.data(result)
      let location = try #require(data["location"] as? [String: Any])
      #expect(location["workspace"] as? String == "acme")
      #expect(location["repo"] as? String == "")
      #expect(location["app"] is NSNull)
      #expect(location["branch"] is NSNull)
      #expect(location["reason"] as? String == "workspace_only")
      #expect(data["current_task"] == nil)
      let sections = try #require(data["sections"] as? [[String: String]])
      #expect(sections.contains { $0["text"]?.hasPrefix("open: AC-2") == true })
      #expect(try WorkspaceSelection.resolve(in: store) == (explicit ? "beta" : "acme"))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/index.db").path)
      )
    }
  }

  @Test func workspaceBriefRetriesKeepSelectors() throws {
    try withScratchDirectory { scratch in
      _ = try fixture.fixture.setup(scratch)
      try fixture.store(scratch).write {
        try $0.database.execute(sql: "DELETE FROM meta WHERE key='current_workspace'")
      }
      let selectors = ["--task", "AC-1", "--topic", "Acme topic"]
      let expected = ["silta --ws 'acme' brief --task 'AC-1' --topic 'Acme topic'"]
      let noSelection = try run(selectors, scratch: scratch)
      let noApp = try run(["--ws", "acme", "--app", "api"] + selectors, scratch: scratch)
      let unknown = try run(["--ws", "missing"], scratch: scratch)
      let unsafe = try run(["--topic", "Acme\nunsafe"], scratch: scratch)
      let missingError = try TaskStateCommandTests.error(noSelection)
      #expect(noSelection.termination == .exit(2))
      #expect(missingError["code"] as? String == "unregistered")
      #expect(missingError["next"] as? [String] == expected)
      let appError = try TaskStateCommandTests.error(noApp)
      #expect(noApp.termination == .exit(1))
      #expect(appError["next"] as? [String] == expected)
      #expect(try TaskStateCommandTests.error(unknown)["code"] as? String == "not_found")
      #expect(try TaskStateCommandTests.error(unsafe)["next"] as? [String] == ["silta ws ls"])
    }
  }

  @Test func workspaceBriefKeepsExplicitTaskAndTopic() throws {
    try withScratchDirectory { scratch in
      _ = try fixture.contextFixture(scratch)
      let result = try run(["--task", "AC-2", "--topic", "payments"], scratch: scratch)
      let data = try fixture.fixture.data(result)
      #expect(data["current_task"] as? String == "AC-2")
      let sections = try #require(data["sections"] as? [[String: String]])
      #expect(sections.contains { $0["text"]?.hasPrefix("open: AC-3") == true })
    }
  }

  @Test func workspaceBriefHasAStableJSONShape() throws {
    try withScratchDirectory { scratch in
      _ = try fixture.fixture.setup(scratch)
      let result = try run([], scratch: scratch)
      try #require(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "brief-workspace.json")
    }
  }

  @Test func workspaceBacklogOverflowHasAScopedContinuation() throws {
    try withScratchDirectory { scratch in
      _ = try fixture.fixture.setup(scratch)
      try fixture.store(scratch).write {
        try $0.database.execute(
          sql: """
            WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<10)
            INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
            SELECT 'acme-'||n,1,n,'Acme backlog','todo','human:acme','','' FROM seq
            """)
      }
      let result = try fixture.run(["--task", "AC-1"], scratch, scratch)
      #expect(result.termination == .exit(0), "\(result.stderr)")
      #expect(result.stdout.contains("2 more open:\nnext: silta --ws 'acme' task ls\n"))
    }
  }

  @Test func workspaceSelectionDoesNotRepairUnrelatedOrBrokenGit() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.fixture.setup(scratch)
      let unrelated = scratch.appending(path: "fixtures/acme-detached")
      let registered = try run(["--ws", "acme"], at: repo, scratch: scratch)
      let data = try fixture.fixture.data(registered)
      #expect((data["location"] as? [String: Any])?["repo"] as? String == "platform")
      let outsideRegistration = try run(["--ws", "acme"], at: unrelated, scratch: scratch)
      #expect(
        try TaskStateCommandTests.error(outsideRegistration)["code"] as? String == "unregistered")
      try Data("broken\n".utf8).write(to: repo.appending(path: ".git/HEAD"))
      let broken = try run(["--ws", "acme"], at: repo, scratch: scratch)
      #expect(try TaskStateCommandTests.error(broken)["code"] as? String == "env")
    }
  }

  private func run(_ args: [String], at path: URL? = nil, scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      ["brief", "--json"] + args, in: scratch, cwd: path ?? scratch,
      environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
  }
}
