import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(3)))
struct WhereOverrideTests {
  private let fixture = WhereCommandTests()

  @Test(arguments: [("unset", false), ("unset", true), ("set", false), ("set", true)])
  func noOpWritesNothing(example: (String, Bool)) throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      if example.0 == "set" {
        _ = try fixture.data(
          fixture.run(["--set", "api", "--approved", "Yes, use api"], repo, scratch))
      }
      let store = store(scratch)
      let before = try snapshot(store)
      let args: [String] =
        (example.0 == "set" ? ["--set", "api"] : ["--unset"])
        + (example.1 ? ["--approved", "Yes"] : [])
      let result = try fixture.run(args, repo, scratch)
      _ = try fixture.data(result)
      #expect(try snapshot(store) == before)
      #expect(result.stdout.contains("approval_unused") == example.1)
      #expect(result.stderr.isEmpty)
    }
  }

  @Test(arguments: ["set", "unset"])
  func noOpReceiptIsAccurateAndQuiet(operation: String) throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      if operation == "set" {
        _ = try fixture.data(
          fixture.run(["--set", "api", "--approved", "Yes, use api"], repo, scratch))
      }
      let args =
        ["--ws", "acme", "where"] + (operation == "set" ? ["--set", "api"] : ["--unset"])
        + ["--approved", "Yes"]
      let result = try SiltaBinary.run(
        args, in: scratch, cwd: repo,
        environment: ["SILTA_ACTOR": "agent:codex:acme"])
      #expect(result.termination == .exit(0))
      #expect(
        result.stdout.hasPrefix(
          operation == "set" ? "Override already api for " : "No override for "))
      #expect(result.stderr.contains("approval_unused"))
      let quiet = try SiltaBinary.run(
        args + ["--quiet"], in: scratch, cwd: repo,
        environment: ["SILTA_ACTOR": "agent:codex:acme"])
      #expect(quiet.termination == .exit(0))
      #expect(quiet.stdout.isEmpty)
      #expect(quiet.stderr.contains("approval_unused"))
    }
  }

  @Test(arguments: [false, true])
  func overrideUsesWorktreeRootAndPreservesSubpaths(setFromNested: Bool) throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let nested = repo.appending(path: "api")
      let setPath = setFromNested ? nested : repo
      _ = try fixture.data(
        fixture.run(["--set", "platform", "--approved", "Yes, use platform"], setPath, scratch))
      #expect(try fixture.data(fixture.run([], repo, scratch))["app"] as? String == "platform")
      #expect(try fixture.data(fixture.run([], nested, scratch))["app"] as? String == "platform")
      let other = scratch.appending(path: "fixtures/acme-portal-worktree")
      #expect(try fixture.data(fixture.run([], other, scratch))["app"] as? String == "portal")
      let console = repo.appending(path: "apps/console")
      #expect(try fixture.data(fixture.run([], console, scratch))["app"] as? String == "console")
      let key = try store(scratch).read {
        try String.fetchOne($0, sql: "SELECT path FROM worktree_override")
      }
      #expect(key == (try canonical(repo)))
    }
  }

  @Test func approvedSubpathRetryFromAnotherCwdKeepsFiltering() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let console = repo.appending(path: "apps/console")
      let refusal = try fixture.run(["--set", "console"], console, scratch)
      #expect(refusal.termination == .exit(3))
      #expect(refusal.stdout.contains(try canonical(repo)))
      let result = try fixture.run(
        ["--path", console.path, "--set", "console", "--approved", "Yes, use console"], scratch,
        scratch)
      #expect(try fixture.data(result)["app"] as? String == "console")
      let key = try store(scratch).read {
        try String.fetchOne($0, sql: "SELECT path FROM worktree_override")
      }
      #expect(key == (try canonical(repo)))
      #expect(try fixture.data(fixture.run([], repo, scratch))["app"] as? String == "api")
    }
  }

  @Test func nestedLinkedWorktreeDoesNotInheritParentOverride() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let child = repo.appending(path: ".claude/worktrees/child")
      try fixture.git(["worktree", "add", "-b", "nested-topic", child.path, "api"], repo, scratch)
      _ = try fixture.data(
        fixture.run(["--set", "platform", "--approved", "Yes, use platform"], repo, scratch))
      #expect(try fixture.data(fixture.run([], repo, scratch))["app"] as? String == "platform")
      #expect(try fixture.data(fixture.run([], child, scratch))["app"] as? String == "api")
    }
  }

  @Test(arguments: [false, true])
  func subpathApprovalNamesAndReplaysWorktreeScope(existingOverride: Bool) throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let console = repo.appending(path: "apps/console")
      let root = try canonical(repo)
      if existingOverride {
        _ = try fixture.data(
          fixture.run(["--set", "platform", "--approved", "Yes, use platform"], repo, scratch))
      }
      let refused = try fixture.run(["--set", "console"], console, scratch)
      try #require(refused.termination == .exit(3))
      let envelope = try #require(
        JSONSerialization.jsonObject(with: Data(refused.stdout.utf8)) as? [String: Any])
      let error = try #require(envelope["error"] as? [String: Any])
      let hint = try #require((error["next"] as? [String])?.first)
      let command = "silta --ws 'acme' where --path " + shellWord(root) + " --set 'console'"
      #expect(hint == command + " --approved \"<the human's words>\"")
      let executable = try SiltaBinary.url().path
      let replay =
        shellWord(executable)
        + hint.dropFirst("silta".count)
        .replacingOccurrences(
          of: "\"<the human's words>\"", with: "'Yes, use console for this worktree'")
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", replay],
        in: scratch, cwd: scratch, environment: ["SILTA_ACTOR": "agent:codex:acme"])
      try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      #expect(result.stdout.hasPrefix("Override set to console for " + root + ".\n"))
      #expect(result.stdout.contains("acme / platform / api"))
      let stored = try store(scratch).read { db in
        try String.fetchOne(
          db,
          sql: """
            SELECT app.slug FROM worktree_override JOIN app ON app.id=worktree_override.app_id
            """)
      }
      #expect(stored == "console")
      #expect(
        try store(scratch).read {
          try String.fetchOne($0, sql: "SELECT command FROM approval ORDER BY id DESC LIMIT 1")
        } == command)
      #expect(try fixture.data(fixture.run([], repo, scratch))["app"] as? String == "api")
      #expect(try fixture.data(fixture.run([], console, scratch))["app"] as? String == "console")
      let again = try SiltaBinary.run(
        ["--ws", "acme", "where", "--path", root, "--set", "console"],
        in: scratch, cwd: scratch, environment: ["SILTA_ACTOR": "agent:codex:acme"])
      #expect(again.termination == .exit(0))
      #expect(again.stdout.hasPrefix("Override already console for " + root + ".\n"))
      #expect(again.stdout.contains("acme / platform / api"))
      #expect(try fixture.run(["--app", "console"], repo, scratch).termination == .exit(4))

    }
  }

  @Test func subpathUnsetNamesWorktreeScope() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let console = repo.appending(path: "apps/console")
      let root = try canonical(repo)
      _ = try fixture.data(
        fixture.run(["--set", "console", "--approved", "Yes, use console"], console, scratch))
      let unset = try fixture.run(["--unset"], console, scratch)
      #expect(unset.termination == .exit(3))
      let unsetCommand = "silta --ws 'acme' where --path " + shellWord(root) + " --unset"
      #expect(unset.stdout.contains(unsetCommand))
      let removed = try SiltaBinary.run(
        ["--ws", "acme", "where", "--path", console.path, "--unset", "--approved", "Yes, remove"],
        in: scratch, cwd: scratch, environment: ["SILTA_ACTOR": "agent:codex:acme"])
      #expect(removed.termination == .exit(0))
      #expect(removed.stdout.hasPrefix("Override removed for " + root + ".\n"))
      #expect(
        try store(scratch).read {
          try String.fetchOne($0, sql: "SELECT command FROM approval ORDER BY id DESC LIMIT 1")
        } == unsetCommand)
    }
  }

  private func store(_ scratch: URL) -> DatabaseStore {
    DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
  }

  private func snapshot(_ store: DatabaseStore) throws -> [String] {
    try store.read { db in
      try ["worktree_override", "approval", "change_log"].map {
        String(try #require(try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")))
      }
        + (try String.fetchAll(
          db,
          sql:
            "SELECT path||':'||app_id||':'||set_by FROM worktree_override ORDER BY path"))
        + ["change_seq", "last_backup_day"].map {
          try #require(
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key=?", arguments: [$0]))
        }
    }
  }

  private func canonical(_ path: URL) throws -> String {
    let sensitive = try path.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
      .volumeSupportsCaseSensitiveNames
    return sensitive == false ? path.path.lowercased() : path.path
  }
}
