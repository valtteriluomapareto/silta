import Darwin
import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(3)))
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
        Golden.forTests().check(first.stdout, "brief.\(suffix)")
        #expect(try first == run(flags, repo, scratch))
      }
      try settings("{\"proposals\":\"triage\",\"review_gate\":\"none\",\"archive_after_days\":14,\"stale_days\":90}", scratch)
      Golden.forTests().check(try run([], repo, scratch).stdout, "brief.txt")
      try settings("{\"proposals\":\"ask\"}", scratch)
      for mode in [[], ["--short"], ["--hook"]] {
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
      try store.write { tx in
        for (seq, app, actor, branch, status) in [
          (1, "api", "agent:codex:other", "api", "doing"),
          (2, "portal", "agent:codex:acme", "elsewhere", "doing"),
          (3, "api", "agent:codex:acme", "elsewhere", "doing"),
          (4, "api", "agent:codex:acme", "api", "done"),
        ] {
          try tx.database.execute(sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,claimed_by,claimed_at,
              branch,created_by,created_at,updated_at,plan_md)
            SELECT ?,workspace_id,?,'Acme task',?,id,?,'2023-11-14T22:13:20.000Z',?,
              'human:acme','2023-11-14T22:13:20.000Z','2023-11-14T22:13:20.000Z',
              '- [x] Acme ready
            - [ ] Acme next'
            FROM app WHERE slug=?
            """, arguments: ["acme-\(seq)", seq, status, actor, branch, app])
        }
      }
      func chosen(_ flags: [String] = []) throws -> String? {
        try fixture.data(run(flags + ["--json"], repo, scratch))["current_task"] as? String
      }
      #expect(try chosen() == "AC-3")
      #expect(try chosen(["--task", "AC-1"]) == "AC-1")
      #expect(try chosen(["--app", "portal"]) == "AC-2")
      let text = try run(["--task", "AC-2", "--app", "api"], repo, scratch).stdout
      #expect(text.contains("app: portal"))
      #expect(text.contains("1. [x] Acme ready\n2. [ ] Acme next"))
      let whereData = try fixture.data(fixture.run([], repo, scratch))
      let brief = try fixture.data(run(["--json"], repo, scratch))
      #expect((brief["location"] as? [String: Any])?["app"] as? String == whereData["app"] as? String)
      try store.write { try $0.database.execute(sql: "UPDATE task SET claimed_by=NULL") }
      #expect(try chosen() == "AC-1")
      try fixture.git(["checkout", "-q", "--detach"], repo, scratch)
      #expect(try chosen() == nil)
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
      #expect(try run([], repo, scratch).termination == .exit(1))
      #expect(try run(["--hook", "--json", "--verbose"], repo, scratch)
        == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
    }
  }

  @Test(arguments: ["git", "database"])
  func hookBoundsBlockedIO(kind: String) throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let fifo = scratch.appending(path: "blocked")
      try #require(mkfifo(fifo.path, 0o600) == 0)
      if kind == "git" {
        let config = repo.appending(path: ".git/config")
        var text = try String(contentsOf: config, encoding: .utf8)
        text += "\n[include]\npath = \(fifo.path)\n"
        try Data(text.utf8).write(to: config)
      } else {
        let path = store(scratch).path
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: fifo.path, toPath: path)
      }
      let clock = ContinuousClock()
      let started = clock.now
      let result = try SiltaBinary.run(
        ["brief", "--hook", "--json", "--verbose"], in: scratch, cwd: repo,
        environment: ["SILTA_ACTOR": "agent:codex"], timeout: 2.5)
      #expect(result == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
      #expect(started.duration(to: clock.now) < .seconds(2))
    }
  }

  func run(_ flags: [String], _ repo: URL, _ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      ["brief", "--ws", "acme"] + flags, in: scratch, cwd: repo,
      environment: ["SILTA_ACTOR": "agent:codex:acme"])
  }

  func store(_ scratch: URL) -> DatabaseStore {
    DatabaseStore(home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
  }

  func settings(_ json: String, _ scratch: URL) throws {
    try store(scratch).write {
      try $0.database.execute(sql: "UPDATE workspace SET settings=?", arguments: [json])
    }
  }
}
