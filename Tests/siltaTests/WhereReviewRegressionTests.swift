import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(3)))
struct WhereReviewRegressionTests {
  private let fixture = WhereCommandTests()

  @Test(arguments: ["checkout", "switch", "worktree"])
  func headCreationReachesDistance(mode: String) throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let cwd: URL
      if mode == "worktree" {
        cwd = scratch.appending(path: "implicit-worktree")
        try fixture.git(["worktree", "add", "-b", "implicit-topic", cwd.path], repo, scratch)
      } else {
        cwd = repo
        let args =
          mode == "switch"
          ? ["switch", "-c", "implicit-topic"] : ["checkout", "-b", "implicit-topic"]
        try fixture.git(args, repo, scratch)
      }
      let data = try fixture.data(fixture.run([], cwd, scratch))
      #expect(data["app"] as? String == "api")
      #expect(data["confidence"] as? String == "high")
      #expect(data["reason"] as? String == "distance")
    }
  }

  @Test func namedNonAppCreationStaysLow() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["branch", "release/2024", "master"], repo, scratch)
      try fixture.git(["branch", "named-topic", "release/2024"], repo, scratch)
      try fixture.git(["checkout", "named-topic"], repo, scratch)
      let data = try fixture.data(fixture.run([], repo, scratch))
      #expect(data["confidence"] as? String == "low")
      #expect(data["reason"] as? String == "non_app_ref")
      #expect(data["app"] == nil)
    }
  }

  @Test(arguments: ["explicit", "override", "task", "single", "subpath"])
  func missingRemoteKeepsConfiguredEvidence(selection: String) throws {
    try withScratchDirectory { scratch in
      _ = try fixture.setup(scratch)
      let repo = scratch.appending(path: "fixtures/acme-missing-remote")
      try fixture.git(
        ["checkout", "-b", "api", "e07a45fbad7104e01181181c5164fb0d2fb593c4"], repo, scratch)
      let store = store(scratch)
      try store.write { tx in
        try tx.database.execute(sql: "UPDATE repo_path SET path=?", arguments: [repo.path])
        if selection == "task" {
          try tx.database.execute(
            sql: """
              INSERT INTO task(uid,workspace_id,seq,title,status,app_id,claimed_by,
                created_by,created_at,updated_at)
              SELECT 'api-task',1,1,'Acme','doing',id,'agent:codex:acme','human:acme','',''
              FROM app WHERE slug='api'
              """)
        }
        if selection == "single" {
          try tx.database.execute(sql: "DELETE FROM app WHERE slug!='api'")
        }
      }
      let args: [String]
      switch selection {
      case "explicit": args = ["--app", "api"]
      case "override": args = ["--set", "api", "--approved", "Yes, use api"]
      default: args = []
      }
      let cwd = selection == "subpath" ? repo.appending(path: "apps/console") : repo
      let result = try fixture.run(args, cwd, scratch)
      let data = try fixture.data(result)
      #expect(data["app"] as? String == (selection == "subpath" ? "console" : "api"))
      #expect(result.stdout.contains("ref_missing"))
    }
  }

  @Test func missingCompetitorsCannotBecomeASingleOrHighDistanceGuess() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      for ref in ["api", "portal"] {
        try fixture.git(["update-ref", "-d", "refs/remotes/origin/" + ref], repo, scratch)
      }
      let data = try fixture.data(fixture.run([], repo, scratch))
      #expect(data["confidence"] as? String == "low")
      #expect(data["app"] == nil)
      #expect((data["candidates"] as? [[String: String]])?.count == 3)
    }
  }

  private func store(_ scratch: URL) -> DatabaseStore {
    DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
  }
}
