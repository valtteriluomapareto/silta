import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct TaskEvidenceCommandTests {
  private let git = CodeCommandTests()

  @Test func commitLinkStoresTheLiteralRootAndFiltersByExactIdentity() throws {
    try withScratchDirectory { scratch in
      let repo = try AcmeWorkspaces.setup(scratch)
      let sha = try oid("refs/remotes/origin/api", repo: repo, scratch: scratch)
      _ = try ok(["task", "add", "--start", "Acme implementation"], scratch)
      _ = try ok(["task", "add", "--start", "Another Acme task"], scratch)
      let alias = "code:api@\(sha.uppercased())"
      let root = "code:api@\(sha):."
      _ = try ok(["task", "link", "AC-1", alias], scratch)
      _ = try ok(["task", "link", "AC-1", root], scratch)
      let store = database(scratch)
      let links = try store.read {
        try String.fetchAll($0, sql: "SELECT to_ext FROM link WHERE to_kind='code'")
      }
      #expect(links == ["api@\(sha):."])
      for target in [alias, root] {
        #expect(try listed(target, scratch) == ["AC-1"])
      }
      let url = "url:https://example.invalid/pr/%2F#Acme"
      _ = try ok(["task", "link", "AC-1", url], scratch)
      #expect(try listed(url, scratch) == ["AC-1"])
      #expect(try listed("url:https://example.invalid/pr/%2f#Acme", scratch).isEmpty)
      #expect(try listed("url:https://example.invalid/pr/%2F#acme", scratch).isEmpty)
      let scoped = try ok(["task", "ls", "--link", alias, "--status", "todo"], scratch)
      #expect(try TaskStateCommandTests.tasks(scoped).isEmpty)
      try oldReaderRoundTrip(scratch, root: root)
    }
  }

  @Test func showAndBriefUseTheConfiguredCachedTipAndNoticeMovedBranch() throws {
    try withScratchDirectory { scratch in
      let repo = try AcmeWorkspaces.setup(scratch)
      let sha = try oid("refs/remotes/origin/api", repo: repo, scratch: scratch)
      let other = try oid("refs/remotes/origin/portal", repo: repo, scratch: scratch)
      try git.git(["update-ref", "refs/heads/api", other], repo, scratch)
      try git.git(["switch", "-c", "acme-work", sha], repo, scratch)
      _ = try ok(["task", "add", "--start", "--app", "api", "Acme evidence"], scratch, cwd: repo)
      _ = try ok(["task", "link", "AC-1", "code:api@\(sha)"], scratch)
      let fetchTime = "2023-11-12T22:13:20.000Z"
      try database(scratch).write {
        try $0.database.execute(sql: "UPDATE repo_path SET fetched_at=?", arguments: [fetchTime])
      }
      let show = try ok(["task", "show", "AC-1"], scratch)
      let observed = try evidence(show)
      let commits = try #require(observed["commits"] as? [[String: String]])
      #expect(commits.first?["ref"] == "refs/remotes/origin/api")
      #expect(commits.first?["tip_sha"] == sha && commits.first?["state"] == "reachable")
      #expect(commits.first?["fetched_at"] == fetchTime)
      #expect(try TaskStateCommandTests.warnings(show).contains("ref_stale"))
      #expect((observed["branch"] as? [String: String])?["source"] == "claim")
      let brief = try ok(["brief", "--task", "AC-1"], scratch)
      #expect(brief.stdout.contains("refs/remotes/origin/api") && brief.stdout.contains("cached"))
      let short = try ok(["brief", "--task", "AC-1", "--short"], scratch)
      #expect(!short.stdout.contains("refs/remotes/origin/api"))
      try git.git(["switch", "--detach", other], repo, scratch)
      try git.git(["update-ref", "refs/heads/acme-work", other], repo, scratch)
      let moved = try ok(["task", "show", "AC-1"], scratch)
      #expect(try TaskStateCommandTests.warnings(moved).contains("task_branch_lacks_commit"))
      try git.git(["branch", "-D", "acme-work"], repo, scratch)
      let lost = try ok(["task", "show", "AC-1"], scratch)
      #expect(try TaskStateCommandTests.warnings(lost).contains("task_branch_missing"))
    }
  }

  @Test func shippedHandoffNamesAMissingBranchEvenWithoutALink() throws {
    try withScratchDirectory { scratch in
      let repo = try AcmeWorkspaces.setup(scratch)
      let sha = try oid("HEAD", repo: repo, scratch: scratch)
      try git.git(["switch", "--detach", sha], repo, scratch)
      _ = try ok(["task", "add", "--start", "--app", "api", "Acme handoff"], scratch, cwd: repo)
      let detached = try ok(["task", "show", "AC-1"], scratch)
      #expect(try TaskStateCommandTests.warnings(detached).isEmpty)
      let body = """
        State: inspected the API.
        Next step: run verification.
        Branch and sha: feature/acme-gone at \(sha).
        """
      _ = try ok(["comment", "AC-1", "--kind", "handoff", "-m", body], scratch)
      let show = try ok(["task", "show", "AC-1"], scratch)
      let observed = try evidence(show)
      #expect((observed["branch"] as? [String: String])?["source"] == "AC-1/1")
      #expect(try TaskStateCommandTests.warnings(show).contains("task_branch_missing"))
      let next = "State: updated; Branch and sha: refs/remotes/origin/api at \(sha)."
      _ = try ok(["comment", "AC-1", "--kind", "handoff", "-m", next], scratch)
      let latest = try evidence(ok(["task", "show", "AC-1"], scratch))
      #expect((latest["branch"] as? [String: String])?["source"] == "AC-1/2")
      #expect((latest["branch"] as? [String: String])?["state"] == "present")
      _ = try ok(["comment", "delete", "AC-1/2"], scratch)
      let surviving = try evidence(ok(["task", "show", "AC-1"], scratch))
      #expect((surviving["branch"] as? [String: String])?["source"] == "AC-1/1")
      _ = try ok(["comment", "AC-1", "--kind", "handoff", "-m", "> Branch: old-quote"], scratch)
      let quoted = try TaskStateCommandTests.data(ok(["task", "show", "AC-1"], scratch))
      #expect(quoted["work_evidence"] == nil)
    }
  }

  @Test func formerAppsAndLegacyCaseMatchWithoutReservingCommitAsAnAppName() throws {
    try withScratchDirectory { scratch in
      let repo = try AcmeWorkspaces.setup(scratch)
      let sha = try oid("refs/remotes/origin/api", repo: repo, scratch: scratch)
      _ = try ok(["task", "add", "--start", "Acme task"], scratch)
      _ = try ok(["task", "link", "AC-1", "code:api@\(sha):."], scratch)
      let store = database(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE link SET to_ext=? WHERE to_kind='code';
            UPDATE app SET slug='delivery',previous_slugs='["api"]' WHERE slug='api';
            INSERT INTO app(uid,workspace_id,repo_id,slug,name,ref,is_primary)
            SELECT 'acme-commit-app',workspace_id,repo_id,'commit','Commit','origin/api',0
            FROM app WHERE slug='delivery';
            """, arguments: ["api@\(sha.uppercased()):."])
      }
      _ = try ok(["task", "link", "AC-1", "code:delivery@\(sha)"], scratch)
      _ = try ok(["task", "link", "AC-1", "commit:README.md"], scratch)
      for owner in ["api", "delivery"] {
        #expect(try listed("code:\(owner)@\(sha)", scratch) == ["AC-1"])
      }
      let rows = try store.read {
        try String.fetchAll($0, sql: "SELECT to_ext FROM link WHERE to_kind='code' ORDER BY id")
      }
      #expect(rows == ["api@\(sha.uppercased()):.", "commit:README.md"])
    }
  }

  private func oldReaderRoundTrip(_ scratch: URL, root: String) throws {
    let exportRoot = scratch.appending(path: "export")
    _ = try ok(["export", "--to", exportRoot.path], scratch)
    if let baseline = ProcessInfo.processInfo.environment["SILTA_BASELINE_BINARY"] {
      try withScratchDirectory { prior in
        let arguments = [
          "restore", exportRoot.appending(path: "acme").path,
          "--approved", "Restore Acme workspace.", "--json",
        ]
        let restored = try SiltaBinary.runProcess(
          URL(filePath: baseline), arguments, in: prior, environment: TaskCommandTests.fixed)
        try #require(restored.termination == .exit(0), "\(restored.stdout)\(restored.stderr)")
        let shown = try SiltaBinary.runProcess(
          URL(filePath: baseline), ["--ws", "acme", "task", "show", "AC-1", "--json"],
          in: prior, environment: TaskCommandTests.fixed)
        #expect(shown.termination == .exit(0) && shown.stdout.contains(root))
      }
    }
    try withScratchDirectory { restored in
      _ = try ok(
        [
          "restore", exportRoot.appending(path: "acme").path, "--approved",
          "Restore Acme workspace.",
        ],
        restored)
      #expect(try listed(root, restored) == ["AC-1"])
      let current = try ok(["task", "show", "AC-1"], restored)
      let result = try evidence(current)
      let commits = try #require(result["commits"] as? [[String: String]])
      #expect(commits.first?["state"] == "unknown")
    }
  }

  private func database(_ scratch: URL) -> DatabaseStore {
    DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
  }

  private func listed(_ target: String, _ scratch: URL) throws -> [String] {
    try TaskStateCommandTests.tasks(ok(["task", "ls", "--link", target], scratch))
      .compactMap { $0["ref"] as? String }
  }

  private func oid(_ ref: String, repo: URL, scratch: URL) throws -> String {
    try git.git(["rev-parse", ref], repo, scratch).trimmingCharacters(in: .newlines)
  }

  private func evidence(_ result: CLIResult) throws -> [String: Any] {
    try #require((try TaskStateCommandTests.data(result))["work_evidence"] as? [String: Any])
  }

  private func ok(_ args: [String], _ scratch: URL, cwd: URL? = nil) throws -> CLIResult {
    let result = try SiltaBinary.run(
      ["--ws", "acme"] + args + ["--deterministic", "--json"], in: scratch, cwd: cwd,
      environment: TaskCommandTests.fixed)
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
    return result
  }
}
