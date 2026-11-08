import CryptoKit
import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

/// Bare `silta` and `silta status` from the outside (spec §16). Goldens were written
/// from the spec.
@Suite(.blockingTestWork, .timeLimit(.minutes(3)))
struct StatusCommandTests {
  static let caller = TaskCommandTests.fixed
  static let other = caller.merging([
    "SILTA_ACTOR": "agent:claude:other", "SILTA_NOW": "2023-11-14T22:13:21.000Z",
  ]) { $1 }

  static let later = caller.merging(["SILTA_NOW": "2023-11-14T22:13:22.000Z"]) { $1 }

  /// The fixture workspace with AC-1 and AC-3 claimed by the caller and AC-2 by another
  /// session; returns the registered repository on the `api` branch. AC-1 is claimed
  /// again after AC-3, so task order differs from claim order.
  static func setup(_ scratch: URL) throws -> URL {
    let fixture = WhereCommandTests()
    let repo = try fixture.setup(scratch)
    try fixture.git(["checkout", "-q", "api"], repo, scratch)
    for (args, actor) in [
      (["task", "add", "Acme status", "--start"], caller),
      (["task", "add", "Acme other", "--start"], other),
      (["task", "add", "Acme next", "--start"], caller),
      (["comment", "AC-1", "--kind", "handoff", "-m", "State: Acme paused."], caller),
      (["task", "start", "AC-1"], later),
    ] {
      let result = try SiltaBinary.run(args, in: scratch, environment: actor)
      try #require(result.termination == .exit(0), "\(args) \(result.stderr)")
    }
    return repo
  }

  static func silta(
    _ args: [String], _ scratch: URL, cwd: URL? = nil, environment: [String: String] = caller
  ) throws -> CLIResult {
    try SiltaBinary.run(args, in: scratch, cwd: cwd, environment: environment)
  }

  @Test func bareSiltaPrintsTheStatusLineInAResolvedRepository() throws {
    try withScratchDirectory { scratch in
      let repo = try Self.setup(scratch)
      let text = try Self.silta([], scratch, cwd: repo)
      #expect(text.termination == .exit(0))
      #expect(text.stderr.isEmpty)
      Golden.forTests().check(text.stdout, "status.txt")
      for args in [["status"], ["--quiet"], ["status", "--quiet"], ["--ws", "acme"]] {
        #expect(try Self.silta(args, scratch, cwd: repo).stdout == text.stdout, "\(args)")
      }
      let json = try Self.silta(["--json"], scratch, cwd: repo)
      #expect(json.termination == .exit(0) && json.stderr.isEmpty)
      Golden.forTests().check(json.stdout, "status.json")
      #expect(try Self.silta(["status", "--json"], scratch, cwd: repo).stdout == json.stdout)
      try WhereCommandTests().git(
        ["update-ref", "-d", "refs/remotes/origin/portal"], repo, scratch)
      #expect(
        try Self.silta(["where", "--json"], scratch, cwd: repo).stdout.contains("ref_missing"))
      let warned = try Self.silta(["--json"], scratch, cwd: repo)
      #expect(warned.stdout.hasSuffix("\"warnings\":[]}\n"))
      #expect(warned.stdout.contains("\"location\":\"resolved\""))
    }
  }

  // The repository's workspace wins over the current one; `--ws` wins over both.
  @Test func workspacePrecedenceAndAnEmptyClaimList() throws {
    try withScratchDirectory { scratch in
      let repo = try Self.setup(scratch)
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"),
        clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
      try store.write {
        try $0.database.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE')")
      }
      try WorkspaceSelection.use("beta", in: store)
      let empty = "workspace beta, app (unregistered), inbox 0, claimed none\n"
      #expect(try Self.silta([], scratch).stdout == empty)
      #expect(try Self.silta(["--ws", "beta"], scratch, cwd: repo).stdout == empty)
      #expect(
        try Self.silta([], scratch, cwd: repo).stdout
          == "workspace acme, app api, inbox 0, claimed AC-1 AC-3\n")
      let json = try WhereCommandTests().data(Self.silta(["--json"], scratch))
      #expect((json["claimed"] as? [Any])?.isEmpty == true)
    }
  }

  // Only `unregistered` falls back: other location failures and an unknown `--ws` are
  // reported as `where` reports them.
  @Test func locationFailuresAndUnknownWorkspacesAreReported() throws {
    try withScratchDirectory { scratch in
      let repo = try Self.setup(scratch)
      for cwd in [repo, scratch.appending(path: "work")] {
        let unknown = try Self.silta(["--ws", "nope", "--json"], scratch, cwd: cwd)
        #expect(unknown.termination == .exit(2))
        #expect(unknown.stdout.contains("\"code\":\"not_found\""))
      }
      #expect(try DogfoodLogTests.last(scratch)["command"] as? String == "silta status")
      try Data("broken\n".utf8).write(to: repo.appending(path: ".git/HEAD"))
      let location = try Self.silta(["where", "--json"], scratch, cwd: repo)
      let status = try Self.silta(["--json"], scratch, cwd: repo)
      #expect(location.termination == .exit(9))
      #expect(status.termination == location.termination)
      #expect(status.stdout.contains("\"code\":\"env\""))
      #expect(!status.stdout.contains("No workspace"))
    }
  }

  @Test func lowConfidencePointsAtWhereAndNeverWritesTheIndex() throws {
    try withScratchDirectory { scratch in
      let repo = try Self.setup(scratch)
      try WhereCommandTests().git(["checkout", "-q", "from-non-app"], repo, scratch)
      let index = scratch.appending(path: "silta-home/index.db")
      let text = try Self.silta([], scratch, cwd: repo)
      #expect(text.termination == .exit(0))
      Golden.forTests().check(text.stdout, "status-unresolved.txt")
      let json = try Self.silta(["--json"], scratch, cwd: repo)
      Golden.forTests().check(json.stdout, "status-unresolved.json")
      #expect(!FileManager.default.fileExists(atPath: index.path))
      // `where` reaches the cached distance tier on the same checkout.
      _ = try Self.silta(["where"], scratch, cwd: repo)
      #expect(FileManager.default.fileExists(atPath: index.path))
    }
  }

  @Test func outsideARegisteredRepositoryTheCurrentWorkspaceStillCounts() throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let outside = try Self.silta([], scratch)
      #expect(outside.termination == .exit(0))
      Golden.forTests().check(outside.stdout, "status-unregistered.txt")
      let json = try Self.silta(["--json"], scratch)
      Golden.forTests().check(json.stdout, "status-unregistered.json")
      let detached = scratch.appending(path: "fixtures/acme-detached")
      #expect(try Self.silta([], scratch, cwd: detached).stdout == outside.stdout)
      #expect(try Self.silta(["--ws", "acme"], scratch).stdout == outside.stdout)
      let other = try Self.silta([], scratch, environment: Self.other)
      #expect(
        other.stdout == "workspace acme, app (unregistered), inbox 0, claimed AC-2\n")
    }
  }

  @Test func noWorkspaceFallsBackWithoutCreatingStorage() throws {
    try withScratchDirectory { scratch in
      let database = scratch.appending(path: "silta-home/silta.db")
      let text = try Self.silta([], scratch)
      #expect(text.termination == .exit(0) && text.stderr.isEmpty)
      Golden.forTests().check(text.stdout, "status-none.txt")
      let json = try Self.silta(["--json"], scratch)
      #expect(json.termination == .exit(0))
      Golden.forTests().check(json.stdout, "status-none.json")
      #expect(!FileManager.default.fileExists(atPath: database.path))
      let unknown = try Self.silta(["--ws", "nope", "--json"], scratch)
      #expect(unknown.termination == .exit(2))
      #expect(unknown.stdout.contains("\"not_found\""))
    }
  }

  @Test func unregisteredRepositoryWithoutSelectionPointsAtWhere() throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"),
        clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
      try store.write {
        try $0.database.execute(sql: "DELETE FROM meta WHERE key='current_workspace'")
      }
      let detached = scratch.appending(path: "fixtures/acme-detached")
      let inGit = try Self.silta([], scratch, cwd: detached)
      #expect(inGit.termination == .exit(0))
      #expect(inGit.stdout == "No workspace here; next: silta where\n")
      #expect(
        try Self.silta(["--json"], scratch, cwd: detached).stdout.contains(
          "{\"location\":\"unregistered\"}"))
      let outside = try Self.silta([], scratch)
      Golden.forTests().check(outside.stdout, "status-none.txt")
    }
  }

  // The count is the caller's own `silta inbox` total, the items past its cap included.
  @Test func inboxCountMatchesTheInboxReadPastItsCap() throws {
    try withScratchDirectory { scratch in
      let repo = try Self.setup(scratch)
      for index in 1...13 {
        let posted = try Self.silta(
          ["comment", "AC-3", "-m", "Acme note \(index)"], scratch, environment: Self.other)
        try #require(posted.termination == .exit(0), "\(posted.stderr)")
      }
      let inbox = try WhereCommandTests().data(Self.silta(["inbox", "--json"], scratch))
      let items = try #require(inbox["items"] as? [[String: Any]])
      let remaining = try #require(inbox["remaining"] as? Int)
      #expect(items.count == 12 && remaining == 1)
      let status = try WhereCommandTests().data(Self.silta(["--json"], scratch, cwd: repo))
      #expect(status["inbox"] as? Int == 13)
      #expect(
        try Self.silta([], scratch, cwd: repo).stdout
          == "workspace acme, app api, inbox 13, claimed AC-1 AC-3\n")
    }
  }

  // Spec §16: the status is a read; truth rows and storage files stay as they were.
  @Test func statusWritesNothingButItsLogLine() throws {
    try withScratchDirectory { scratch in
      let repo = try Self.setup(scratch)
      let home = scratch.appending(path: "silta-home")
      try WhereCommandTests().git(["checkout", "-q", "from-non-app"], repo, scratch)
      _ = try Self.silta(["where"], scratch, cwd: repo)
      try #require(FileManager.default.fileExists(atPath: home.appending(path: "index.db").path))
      let before = try Self.snapshot(home)
      for (args, cwd) in [
        ([], repo), (["--json"], repo), ([], scratch), (["--ws", "acme"], scratch),
        (["status", "--approved", "Acme yes"], repo),
      ] {
        let result = try Self.silta(args, scratch, cwd: cwd)
        #expect(result.termination == .exit(0), "\(args) \(result.stderr)")
      }
      #expect(try Self.snapshot(home) == before)
    }
  }

  @Test(arguments: [["--help"], ["-h"], ["help"], ["--help", "--json"]])
  func helpStaysReachable(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      for environment in [Self.caller, Self.caller.merging(["SILTA_NOW": "bad"]) { $1 }] {
        let result = try Self.silta(arguments, scratch, environment: environment)
        #expect(result.termination == .exit(0))
        #expect(result.stdout.hasPrefix("OVERVIEW: A local context hub"), "\(arguments)")
        #expect(result.stdout.contains("status (default)"))
        #expect(result.stderr.isEmpty)
      }
    }
  }

  @Test func versionAndBrokenEnvironmentKeepTheirContracts() throws {
    try withScratchDirectory { scratch in
      let broken = Self.caller.merging(["SILTA_NOW": "bad"]) { $1 }
      let version = try Self.silta(["--version"], scratch, environment: broken)
      #expect(
        version == CLIResult(termination: .exit(0), stdout: SiltaVersion.current + "\n", stderr: "")
      )
      let bare = try Self.silta(["--json"], scratch, environment: broken)
      #expect(bare.termination == .exit(9))
      #expect(bare.stdout.contains("\"env\""))
      let text = try Self.silta([], scratch, environment: broken)
      #expect(text.termination == .exit(9) && text.stdout.isEmpty)
      #expect(text.stderr.contains("[env]"))
      let flag = try Self.silta(["--bogus", "--json"], scratch)
      #expect(flag.termination == .exit(1))
      #expect(flag.stdout.contains("\"next\":[\"silta --help\"]"))
      let typo = try Self.silta(["stauts", "--json"], scratch)
      #expect(typo.termination == .exit(1))
      #expect(typo.stdout.contains("\"next\":[\"silta --help\"]"))
    }
  }

  @Test func bareSiltaLogsAsStatusWithItsWorkspace() throws {
    try withScratchDirectory { scratch in
      let repo = try Self.setup(scratch)
      _ = try Self.silta([], scratch, cwd: repo)
      let entry = try DogfoodLogTests.last(scratch)
      #expect(entry["command"] as? String == "silta status")
      #expect(entry["workspace"] as? String == "acme")
      #expect(entry["app"] == nil)
    }
  }
}

extension StatusCommandTests {
  @Test(arguments: [
    (["--help"], "OVERVIEW: A local context hub"),
    (["-h"], "OVERVIEW: A local context hub"),
    (["help"], "OVERVIEW: A local context hub"),
    (["--version"], SiltaVersion.current),
    (["task", "--help"], "OVERVIEW: Keep task work, plans and results"),
    (["task", "-h"], "OVERVIEW: Keep task work, plans and results"),
    (["help", "task"], "OVERVIEW: Keep task work, plans and results"),
    (["task", "ls", "--help"], "OVERVIEW: List workspace tasks"),
    (["help", "task", "ls"], "OVERVIEW: List workspace tasks"),
    (["--bogus"], nil),
    (["stauts"], nil),
    (["task", "ls", "--bogus"], nil),
  ])
  func parseResultsSurviveBrokenEnvironment(
    arguments: [String], expectedPrefix: String?
  ) throws {
    try withScratchDirectory { scratch in
      for broken in [false, true] {
        let environment =
          broken ? Self.caller.merging(["SILTA_NOW": "bad"]) { $1 } : Self.caller
        for invocation in [arguments, ["--json"] + arguments, arguments + ["--json"]] {
          let result = try Self.silta(invocation, scratch, environment: environment)
          let json = invocation.contains("--json")
          if let expectedPrefix {
            #expect(result.termination == .exit(0), "\(invocation), broken: \(broken)")
            #expect(result.stdout.hasPrefix(expectedPrefix), "\(invocation), broken: \(broken)")
            #expect(result.stderr.isEmpty, "\(invocation), broken: \(broken)")
          } else {
            #expect(result.termination == .exit(1), "\(invocation), broken: \(broken)")
            if json {
              #expect(result.stdout.contains("\"code\":\"usage\""))
              #expect(result.stdout.contains("\"ok\":false"))
              #expect(result.stderr.isEmpty, "\(invocation), broken: \(broken)")
            } else {
              #expect(result.stdout.isEmpty)
              #expect(result.stderr.contains("[usage]"))
            }
          }
        }
      }
    }
  }

  /// Every storage file but the command log, by content, with truth rows read
  /// logically: a read connection may checkpoint the WAL, which changes bytes but not
  /// rows.
  static func snapshot(_ home: URL) throws -> [String] {
    let files = try FileManager.default.subpathsOfDirectory(atPath: home.path).filter {
      !$0.hasPrefix("log") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm")
        && !$0.hasPrefix("silta.db")
    }.sorted().map { path in
      guard let data = FileManager.default.contents(atPath: home.appending(path: path).path)
      else { return path }
      return path + " " + SHA256.hash(data: data).description
    }
    let queue = try DatabaseQueue(path: home.appending(path: "silta.db").path)
    let rows = try queue.read { db in
      try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
      ).flatMap { table in
        try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"").map { table + " " + $0.description }
      }
    }
    return files + rows
  }
}
