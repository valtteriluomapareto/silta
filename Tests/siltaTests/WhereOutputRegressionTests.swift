import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(3)))
struct WhereOutputRegressionTests {
  private let fixture = WhereCommandTests()

  @Test func rankedLowTextHasRefsAndSurvivesCacheHits() throws {
    try withScratchDirectory { scratch in
      let repo = try lowFixture(scratch)
      let first = try text([], repo, scratch)
      Golden.forTests().check(try normalized(first.stdout, repo: repo), "where-low-ranked.txt")
      let second = try text([], repo, scratch)
      #expect(second.stdout == first.stdout)
      try fixture.git(["update-ref", "-d", "refs/remotes/origin/api"], repo, scratch)
      let missing = try text([], repo, scratch)
      Golden.forTests().check(try normalized(missing.stdout, repo: repo), "where-low-missing.txt")
      #expect(missing.stderr.contains("ref_missing"))
      #expect(try text([], repo, scratch).stdout == missing.stdout)
    }
  }

  @Test func lowRetriesUseCanonicalInspectedPath() throws {
    try withScratchDirectory { scratch in
      let repo = try lowFixture(scratch)
      let alias = scratch.appending(path: "MiXeD-link")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
      let result = try text(["--path", alias.path], scratch, scratch)
      #expect(result.stdout.contains("--path " + shellWord(try canonical(repo))))
      #expect(!result.stdout.contains(alias.path))
    }
  }

  @Test(arguments: ["set", "already", "unset", "absent"])
  func canonicalOverrideReceiptsUseWorktreeRoot(operation: String) throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      if operation == "already" || operation == "unset" {
        _ = try fixture.data(
          fixture.run(
            ["--set", "platform", "--approved", "Yes, use platform"], repo, scratch))
      }
      let alias = scratch.appending(path: "MiXeD-link")
      try FileManager.default.createSymbolicLink(
        at: alias, withDestinationURL: repo.appending(path: "api"))
      let args =
        ["--path", alias.path]
        + (operation == "set" || operation == "already" ? ["--set", "platform"] : ["--unset"])
        + ["--approved", "Yes"]
      let result = try text(args, scratch, scratch)
      #expect(result.termination == .exit(0))
      Golden.forTests().check(
        try normalized(result.stdout, repo: repo), "where-override-\(operation).txt")
    }
  }

  @Test func outsideGitDoesNotSuggestScanningRoot() throws {
    try withScratchDirectory { scratch in
      _ = try fixture.setup(scratch)
      let result = try fixture.run(["--path", "/"], scratch, scratch)
      #expect(result.termination == .exit(2))
      #expect(result.stdout.contains("Carry on without Silta"))
      #expect(!result.stdout.contains("init --scan"))
      Golden.forTests().check(result.stdout, "where-outside-git.json")
    }
  }

  @Test func missingTaskRetryUsesInferredWorkspace() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"),
        clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Acme Beta','BE');
            UPDATE meta SET value='beta' WHERE key='current_workspace';
            """)
      }
      let result = try SiltaBinary.run(
        ["where", "--path", repo.path, "--task", "AC-999", "--json"], in: scratch, cwd: scratch,
        environment: ["SILTA_ACTOR": "agent:codex:acme"])
      #expect(result.termination == .exit(2))
      #expect(result.stdout.contains("silta --ws 'acme' task ls"))
      Golden.forTests().check(result.stdout, "where-task-not-found.json")
    }
  }

  private func lowFixture(_ scratch: URL) throws -> URL {
    let repo = try fixture.setup(scratch)
    try fixture.git(["checkout", "-qb", "score-topic", "portal"], repo, scratch)
    try Data("Acme score\n".utf8).write(to: repo.appending(path: "score.txt"))
    try fixture.git(["add", "score.txt"], repo, scratch)
    try fixture.git(
      [
        "-c", "user.name=Acme", "-c", "user.email=acme@example.invalid",
        "commit", "-qm", "Add score fixture",
      ], repo, scratch)
    try fixture.git(["checkout", "-q", "--detach", "HEAD"], repo, scratch)
    return repo
  }

  private func text(_ args: [String], _ cwd: URL, _ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      ["--ws", "acme", "where"] + args, in: scratch, cwd: cwd,
      environment: ["SILTA_ACTOR": "agent:codex:acme"])
  }

  private func canonical(_ path: URL) throws -> String {
    let sensitive = try path.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
      .volumeSupportsCaseSensitiveNames
    return sensitive == false ? path.path.lowercased() : path.path
  }

  private func normalized(_ text: String, repo: URL) throws -> String {
    text.replacingOccurrences(of: try canonical(repo), with: "<path>")
      .replacingOccurrences(
        of: "head: [a-f0-9]+", with: "head: <head>", options: .regularExpression)
  }
}
