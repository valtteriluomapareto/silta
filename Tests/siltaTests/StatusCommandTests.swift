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

  /// The fixture workspace with AC-1 and AC-3 claimed by the caller and AC-2 by another
  /// session; returns the registered repository on the `api` branch.
  static func setup(_ scratch: URL) throws -> URL {
    let fixture = WhereCommandTests()
    let repo = try fixture.setup(scratch)
    try fixture.git(["checkout", "-q", "api"], repo, scratch)
    for (title, actor) in [("Acme status", caller), ("Acme other", other), ("Acme next", caller)] {
      let added = try SiltaBinary.run(
        ["task", "add", title, "--start"], in: scratch, environment: actor)
      try #require(added.termination == .exit(0), "\(added.stderr)")
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
          ["comment", "AC-1", "-m", "Acme note \(index)"], scratch, environment: Self.other)
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

  /// Every storage file but the command log, with truth rows read logically: a read
  /// connection may checkpoint the WAL, which changes bytes but not rows.
  static func snapshot(_ home: URL) throws -> [String] {
    let files = try FileManager.default.subpathsOfDirectory(atPath: home.path).filter {
      !$0.hasPrefix("log") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm")
        && !$0.hasPrefix("silta.db")
    }.sorted()
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
