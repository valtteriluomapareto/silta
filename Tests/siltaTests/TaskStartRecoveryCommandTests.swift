import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct TaskStartRecoveryCommandTests {
  private let fixture = WhereCommandTests()
  private let actor = ["SILTA_ACTOR": "agent:codex", "SILTA_NOW": "2023-11-14T22:13:20.000Z"]

  @Test(arguments: [false, true])
  func retryClaimsInTheRegisteredCloneAndKeepsTheSession(inOtherRepo: Bool) throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let wrong = inOtherRepo ? scratch.appending(path: "fixtures/acme-detached") : scratch
      let starts = ["task", "start", "AC-1", "--json"]
      let refusal = try run(starts, at: wrong, scratch: scratch)
      #expect(try task(at: repo, scratch: scratch)["claimed_by"] == nil)

      let error = try TaskStateCommandTests.error(refusal)
      #expect(refusal.termination == .exit(1))
      #expect(error["code"] as? String == "invalid")
      #expect(error["next_by"] as? String == "agent")
      let normalized = refusal.stdout.replacingOccurrences(
        of: scratch.path + "/", with: "<scratch>/")
      Golden.forTests().check(normalized, "task-start-directory.json")
      let command = try #require((error["next"] as? [String])?.first)
      try #require(command.hasPrefix("cd " + shellWord(repo.path) + " && "))
      let retry = try execute(command, at: wrong, scratch: scratch)
      try #require(retry.termination == .exit(0), "\(retry.stdout)\(retry.stderr)")

      let claimed = try task(at: repo, scratch: scratch)
      #expect(claimed["branch"] as? String == "task-work")
      let path = try #require(claimed["worktree"] as? String)
      #expect(
        URL(filePath: path).resolvingSymlinksInPath().path == repo.resolvingSymlinksInPath().path)
      let plan = try run(
        ["task", "plan", "AC-1", "-m", "Acme steps\n- [ ] Continue"], at: repo, scratch: scratch)
      #expect(plan.termination == .exit(0), "\(plan.stdout)\(plan.stderr)")
    }
  }

  @Test func approvedStealDoesNotEchoOrConsumeTheApprovalOnRefusal() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let store = BriefCommandTests().store(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE task
            SET status='doing',claimed_by='agent:codex:other',
              claimed_at='2023-11-14T22:13:20.000Z',worktree=?
            """, arguments: [repo.path])
      }
      let words = "Let Acme resume the claim."
      let refusal = try run(
        ["task", "start", "AC-1", "--steal", "--approved", words, "--json"],
        at: scratch, scratch: scratch)
      #expect(!refusal.stdout.contains(words) && !refusal.stderr.contains(words))
      #expect(try task(at: repo, scratch: scratch)["claimed_by"] as? String == "agent:codex:other")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)

      let error = try TaskStateCommandTests.error(refusal)
      let next = try #require(error["next"] as? [String])
      #expect((error["message"] as? String)?.contains("Reuse the original approval") == true)
      #expect(next.first == "silta --ws 'acme' task show 'AC-1'")
      let command = try #require(next.last)
      let placeholder = #""<the human's words>""#
      try #require(command.hasSuffix(" --steal --approved " + placeholder))
      let retry = try execute(
        command.replacingOccurrences(of: placeholder, with: shellWord(words)),
        at: scratch, scratch: scratch)
      try #require(retry.termination == .exit(0), "\(retry.stdout)\(retry.stderr)")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
      let owner = try #require(task(at: repo, scratch: scratch)["claimed_by"] as? String)
      #expect(owner != "agent:codex:other")
    }
  }

  @Test func unsafeClonePathGetsAReadOnlyLookup() throws {
    try withScratchDirectory { scratch in
      _ = try setup(scratch, name: "Acme\nunsafe")
      let refusal = try run(["task", "start", "AC-1", "--json"], at: scratch, scratch: scratch)
      let error = try TaskStateCommandTests.error(refusal)
      #expect(error["code"] as? String == "invalid")
      #expect(error["next_by"] as? String == "agent")
      #expect(error["next"] as? [String] == ["silta --ws 'acme' ws show"])
      #expect(!refusal.stdout.contains("Acme\\nunsafe"))
    }
  }

  @Test func realGitFailuresStayEnvironmentErrors() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let wrong = scratch.appending(path: "fixtures/acme-detached")
      try Data("broken\n".utf8).write(to: wrong.appending(path: ".git/HEAD"))
      let args = ["task", "start", "AC-1", "--json"]
      let brokenCwd = try run(args, at: wrong, scratch: scratch)
      #expect(try TaskStateCommandTests.error(brokenCwd)["code"] as? String == "env")
      let dangling = scratch.appending(path: "dangling-git")
      try FileManager.default.createDirectory(at: dangling, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: dangling.appending(path: ".git"), withDestinationURL: scratch.appending(path: "missing")
      )
      let brokenMarker = try run(args, at: dangling, scratch: scratch)
      #expect(try TaskStateCommandTests.error(brokenMarker)["code"] as? String == "env")
      try Data("broken\n".utf8).write(to: repo.appending(path: ".git/HEAD"))
      let brokenRegistered = try run(args, at: scratch, scratch: scratch)
      #expect(try TaskStateCommandTests.error(brokenRegistered)["code"] as? String == "env")
      #expect(brokenRegistered.stdout.contains("silta doctor"))
    }
  }

  @Test func linkedWorktreeCanClaimDirectly() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let linked = scratch.appending(path: "linked")
      try fixture.git(["worktree", "add", "-qb", "linked-work", linked.path], repo, scratch)
      let start = try run(["task", "start", "AC-1"], at: linked, scratch: scratch)
      try #require(start.termination == .exit(0), "\(start.stdout)\(start.stderr)")
      let recorded = try task(at: linked, scratch: scratch)
      #expect(recorded["branch"] as? String == "linked-work")
      let worktree = try #require(recorded["worktree"] as? String)
      #expect(
        URL(filePath: worktree).resolvingSymlinksInPath().path
          == linked.resolvingSymlinksInPath().path)
    }
  }

  private func setup(_ scratch: URL, name: String = "Acme's clone") throws -> URL {
    let source = try fixture.setup(scratch)
    let repo = scratch.appending(path: name)
    try fixture.git(["clone", "--quiet", source.path, repo.path], scratch, scratch)
    try fixture.git(["checkout", "-qb", "task-work"], repo, scratch)
    try BriefCommandTests().store(scratch).write {
      try $0.database.execute(
        sql: """
          UPDATE repo_path SET path=?;
          INSERT INTO task(
            uid,workspace_id,seq,title,status,app_id,created_by,created_at,updated_at)
          SELECT 'acme-start',workspace_id,1,'Acme starting task','todo',id,'human:acme',
            '2023-11-14T22:13:20.000Z','2023-11-14T22:13:20.000Z' FROM app WHERE slug='api';
          """, arguments: [repo.path])
    }
    return repo
  }

  private func run(_ args: [String], at cwd: URL, scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(["--ws", "acme"] + args, in: scratch, cwd: cwd, environment: actor)
  }

  private func task(at cwd: URL, scratch: URL) throws -> [String: Any] {
    try fixture.data(run(["task", "show", "AC-1", "--json"], at: cwd, scratch: scratch))
  }

  private func execute(_ command: String, at cwd: URL, scratch: URL) throws -> CLIResult {
    var environment = actor
    environment["PATH"] = try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
    return try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"), ["-ec", command], in: scratch, cwd: cwd, environment: environment)
  }
}
