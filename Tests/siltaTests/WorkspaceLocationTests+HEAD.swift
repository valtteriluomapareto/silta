import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension WorkspaceLocationTests {
  @Test func whereNamesABranchSharedWithATag() throws {
    try withScratchDirectory { scratch in
      let (repo, _) = try Self.setup(scratch)
      try Self.git(["switch", "-qc", "team/acme"], in: repo, scratch: scratch)
      try Self.git(["tag", "team/acme"], in: repo, scratch: scratch)
      let attached = try Self.run(["where", "--json"], scratch, repo)
      try #require(attached.termination == .exit(0))
      #expect(attached.stdout.contains("\"branch\":\"team/acme\""))
      try Self.git(["switch", "-q", "--detach"], in: repo, scratch: scratch)
      let detached = try Self.run(["where", "--json"], scratch, repo)
      #expect(detached.termination == .exit(0))
      #expect(detached.stdout.contains("\"branch\":null"))
    }
  }

  @Test func tagCollisionKeepsBranchTaskEvidence() throws {
    try withScratchDirectory { scratch in
      let (repo, store) = try Self.setup(scratch)
      try Self.git(["switch", "-qc", "team/acme"], in: repo, scratch: scratch)
      try Self.git(["tag", "team/acme"], in: repo, scratch: scratch)
      let created = try Self.run(
        [
          "--ws", "acme", "task", "add", "Acme branch task", "--app", "acme-platform-portal",
          "--start", "--json",
        ], scratch, repo)
      try #require(created.termination == .exit(0), "\(created.stdout)\(created.stderr)")
      let stored = try store.read {
        try String.fetchOne($0, sql: "SELECT branch FROM task WHERE seq=2")
      }
      func whereFromAnotherSession() throws -> String {
        let other = Self.environment.merging(["SILTA_ACTOR": "agent:codex:other"]) { _, new in new }
        let result = try SiltaBinary.run(
          ["where", "--json"], in: scratch, cwd: repo, environment: other)
        try #require(result.termination == .exit(0))
        return result.stdout
      }
      let canonical = try whereFromAnotherSession()
      try store.write {
        try $0.database.execute(sql: "UPDATE task SET branch='heads/team/acme' WHERE seq=2")
      }
      let legacy = try whereFromAnotherSession()
      withKnownIssue("#264: tag ambiguity loses branch task evidence") {
        #expect(stored == "team/acme")
        #expect(canonical.contains("\"reason\":\"task\""))
        #expect(legacy.contains("\"reason\":\"task\""))
      }
      try Self.git(
        ["update-ref", "refs/heads/heads/team/acme", "HEAD"], in: repo, scratch: scratch)
      #expect(try !whereFromAnotherSession().contains("\"reason\":\"task\""))
    }
  }

  @Test func wherePreservesACombiningMarkAtTheStartOfTheBranch() throws {
    try withScratchDirectory { scratch in
      let (repo, _) = try Self.setup(scratch)
      let name = "\u{0301}acme"
      try Self.git(["switch", "-qc", name], in: repo, scratch: scratch)
      let result = try Self.run(["where", "--json"], scratch, repo)
      withKnownIssue("#264: branch names use Git byte offsets") {
        #expect(result.termination == .exit(0))
        #expect(result.stdout.contains("\"branch\":\"\(name)\""))
      }
    }
  }

  @Test func whereReportsAnUnbornBranch() throws {
    try withScratchDirectory { scratch in
      let (repo, _) = try Self.setup(scratch)
      try Self.git(["symbolic-ref", "HEAD", "refs/heads/unborn"], in: repo, scratch: scratch)
      let json = try Self.run(["where", "--json"], scratch, repo)
      let text = try Self.run(["where"], scratch, repo)
      #expect(json.termination == .exit(0))
      #expect(json.stdout.contains("\"branch\":\"unborn\""))
      #expect(json.stdout.contains("\"head\":\"\""))
      #expect(json.stdout.contains("\"reason\":\"unresolved\""))
      #expect(text.stdout.contains("head: (no commits)"))
    }
  }

  @Test func whereKeepsBrokenAttachedHEADAsAnEnvironmentFailure() throws {
    try withScratchDirectory { scratch in
      let (repo, _) = try Self.setup(scratch)
      try Self.git(["symbolic-ref", "HEAD", "refs/heads/acme-broken"], in: repo, scratch: scratch)
      let ref = repo.appending(path: ".git/refs/heads/acme-broken")
      try Data((String(repeating: "a", count: 40) + "\n").utf8).write(to: ref)
      let result = try Self.run(["where", "--json"], scratch, repo)
      #expect(result.termination == .exit(9))
      #expect(result.stdout.contains("\"code\":\"env\""))
      #expect(result.stdout.contains("\"next\":[\"silta doctor\"]"))
    }
  }

  private static func git(_ arguments: [String], in repo: URL, scratch: URL) throws {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), arguments, in: scratch, cwd: repo)
    try #require(result.termination == .exit(0), "\(result.stderr)")
  }
}
