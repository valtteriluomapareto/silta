import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct AppDisplayNameCommandTests {
  private static let scoped = ["--ws", "acme"]
  private static let env = TaskCommandTests.fixed

  @Test func setChangeAndRemoveNameWithUnchangedStampedReplay() throws {
    try withScratchDirectory { scratch in
      _ = try Self.scan(scratch)
      let store = Self.store(scratch)
      let initial = try Self.state(store)
      #expect(initial.name == "platform")
      for (authored, expected) in [
        ("Acme Platform", "Acme Platform"), ("Plateforme Acmé", "Plateforme Acmé"),
        (nil, "platform"), ("platform", "platform"),
      ] {
        let saved = try Self.edit(Self.configuration(name: authored), in: scratch)
        try #require(saved.termination == .exit(0), "\(saved.stderr)")
        let captured = try Self.state(store)
        #expect(captured.uid == initial.uid)
        #expect(captured.name == expected)
        let stamped = try Self.shown(in: scratch)
        #expect(stamped.hasPrefix("# silta-base: "))
        #expect(stamped.contains(#""name":""# + expected + #"""#) == (expected != "platform"))
        let json = try Self.run(["ws", "show", "--json"], in: scratch)
        #expect(try TaskStateCommandTests.data(json)["yaml"] as? String == stamped)
        let replayed = try Self.edit(stamped, in: scratch)
        #expect(replayed.termination == .exit(0) && replayed.stdout == "No changes.\n")
        #expect(try Self.state(store) == captured)
        #expect(try Self.shown(in: scratch) == stamped)
        if expected == "Plateforme Acmé" {
          let restored = try Self.restoreIntoFreshHome(from: scratch)
          #expect(
            try Self.state(Self.store(scratch, home: restored["SILTA_HOME"])).name == expected)
          #expect(try Self.shown(in: scratch, env: restored).contains(expected))
        }
      }
    }
  }

  @Test func briefAndScanListNameAlongsideSlugWhileRoutingUsesSlug() throws {
    try withScratchDirectory { scratch in
      let repo = try Self.scan(scratch)
      let saved = try Self.edit(Self.configuration(name: "Acme Platform"), in: scratch)
      try #require(saved.termination == .exit(0), "\(saved.stderr)")
      let scan = ["init", "--scan", repo.path]
      for json in [false, true] {
        let result = try Self.run(scan + (json ? ["--json"] : []), in: scratch)
        try #require(result.termination == .exit(0), "\(result.stdout + result.stderr)")
        Golden.forTests().check(
          result.stdout, json ? "init-rescan-app-name.json" : "init-rescan-app-name.txt")
        if json {
          let schema = try SiltaBinary.run(["schema", "init", "--json"], in: scratch)
          let commands = try #require(
            try TaskStateCommandTests.data(schema)["commands"] as? [[String: Any]])
          let shape = try #require(commands.first?["data"])
          #expect(
            ShapeCheck.violations(of: try TaskStateCommandTests.data(result), against: shape)
              .isEmpty)
        }
      }
      let arguments = ["brief", "--app", "platform"]
      let text = try Self.run(arguments, in: scratch, cwd: repo)
      #expect(text.termination == .exit(0))
      #expect(text.stdout.split(separator: "\n").contains("app: platform (Acme Platform)"))
      let brief = try Self.run(arguments + ["--json"], in: scratch, cwd: repo)
      let data = try TaskStateCommandTests.data(brief)
      let sections = try #require(data["sections"] as? [[String: String]])
      #expect(sections.contains(["id": "app", "text": "app: platform (Acme Platform)\n"]))
      #expect((data["location"] as? [String: Any])?["app"] as? String == "platform")
      let missing = try Self.run(
        ["where", "--app", "Acme Platform", "--json"], in: scratch, cwd: repo)
      #expect(missing.termination == .exit(2))
      let error = try TaskStateCommandTests.error(missing)
      #expect(error["code"] as? String == "not_found")
      let next = try #require(error["next"] as? [String])
      #expect(next == ["silta --ws 'acme' ws show"])
      let command = try #require(next.first)
      let shown = try FirstWorkspaceCommandTests.replay(command, in: scratch, cwd: repo)
      #expect(shown.termination == .exit(0) && shown.stdout.contains("Acme Platform"))
      let code = try Self.run(["code", "show", "platform", "--", "readme"], in: scratch, cwd: repo)
      #expect(code.termination == .exit(0) && code.stdout.contains("Acme"))
      let wrongEdge = Self.configuration(name: "Acme Platform").replacingOccurrences(
        of: "from: platform", with: "from: Acme Platform")
      let refused = try Self.edit(wrongEdge, in: scratch)
      #expect(refused.termination == .exit(1) && refused.stderr.contains("unknown apps slug"))
      let duplicateLabel = try Self.edit(Self.configuration(name: "portal"), in: scratch)
      try #require(duplicateLabel.termination == .exit(0), "\(duplicateLabel.stderr)")
      let portal = try Self.run(["where", "--app", "portal", "--json"], in: scratch, cwd: repo)
      #expect(try TaskStateCommandTests.data(portal)["app"] as? String == "portal")
    }
  }

  @Test func restoredLegacyNameKeepsItsExactBytesDuringWorkspaceEdits() throws {
    try withScratchDirectory { scratch in
      _ = try Self.scan(scratch)
      let legacy = "Acme\u{0085}" + String(repeating: "x", count: 121)
      try Self.store(scratch).write { tx in
        try tx.database.execute(
          sql: "UPDATE app SET name=? WHERE slug='platform'", arguments: [legacy])
      }
      let env = try Self.restoreIntoFreshHome(from: scratch)
      let store = Self.store(scratch, home: env["SILTA_HOME"])
      let baseline = try Self.state(store)
      #expect(Array(baseline.name.utf8) == Array(legacy.utf8))
      let stamped = try Self.shown(in: scratch, env: env)
      #expect(stamped.contains(#""name":"Acme\u0085"#))
      let replayed = try Self.edit(stamped, in: scratch, env: env)
      #expect(replayed.termination == .exit(0) && replayed.stdout == "No changes.\n")
      #expect(try Self.state(store) == baseline)
      let unrelated = stamped.replacingOccurrences(of: "services: []", with: "services: [mailer]")
      let changed = try Self.edit(unrelated, in: scratch, env: env)
      try #require(changed.termination == .exit(0), "\(changed.stderr)")
      let preserved = try Self.state(store)
      #expect(preserved.uid == baseline.uid)
      #expect(Array(preserved.name.utf8) == Array(legacy.utf8))
      #expect(preserved.changeSequence != baseline.changeSequence)
      let beforeInvalid = try Self.shown(in: scratch, env: env)
      let invalid = beforeInvalid.replacingOccurrences(of: #"Acme\u0085"#, with: #"New\u0085"#)
      let refused = try Self.edit(invalid, in: scratch, env: env)
      #expect(refused.termination == .exit(1))
      #expect(refused.stderr.contains("app name"))
      #expect(try Self.state(store) == preserved)
      #expect(try Self.shown(in: scratch, env: env) == beforeInvalid)
    }
  }

  private struct AppState: Equatable {
    let uid: String
    let name: String
    let changeSequence: String
    let approvals: Int
  }

  private static func state(_ store: DatabaseStore) throws -> AppState {
    try store.read { db in
      let app = try #require(
        try Row.fetchOne(db, sql: "SELECT uid,name FROM app WHERE slug='platform'"))
      let change = try #require(
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='change_seq'"))
      let approvals = try #require(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval"))
      return AppState(
        uid: app["uid"], name: app["name"], changeSequence: change, approvals: approvals)
    }
  }

  private static func configuration(name: String?) -> String {
    let field = name.map { ", name: " + $0.debugDescription } ?? ""
    return """
      workspace: {slug: acme, name: acme, task_prefix: AC}
      repos: [{slug: platform}]
      apps:
        - {slug: platform, repo: platform, ref: origin/main\(field)}
        - {slug: portal, repo: platform, ref: origin/portal}
      edges: [{from: platform, to: portal, kind: calls, summary: Acme portal}]
      """ + "\n"
  }

  private static func scan(_ scratch: URL) throws -> URL {
    let repo = scratch.appending(path: "platform")
    try InitCommandTests.makeRepo(repo, in: scratch)
    try InitCommandTests.git(
      ["update-ref", "refs/remotes/origin/portal", "HEAD"], in: scratch, cwd: repo)
    let scanned = try SiltaBinary.run(["init", "--scan", repo.path, "--slug", "acme"], in: scratch)
    try #require(scanned.termination == .exit(0), "\(scanned.stderr)")
    return repo
  }

  private static func store(_ scratch: URL, home: String? = nil) -> DatabaseStore {
    DatabaseStore(
      home: home.map { URL(filePath: $0) } ?? scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
  }

  private static func restoreIntoFreshHome(from scratch: URL) throws -> [String: String] {
    let export = try run(["export", "--to", "out"], in: scratch)
    try #require(export.termination == .exit(0), "\(export.stderr)")
    var restored = env
    restored["SILTA_HOME"] = scratch.appending(path: "restored-home").path
    let restore = try SiltaBinary.run(
      ["restore", "out/acme", "--approved", "Restore the Acme fixture"],
      in: scratch, environment: restored)
    try #require(restore.termination == .exit(0), "\(restore.stderr)")
    return restored
  }

  private static func shown(in scratch: URL, env: [String: String] = env) throws -> String {
    let result = try run(["ws", "show"], in: scratch, env: env)
    try #require(result.termination == .exit(0), "\(result.stderr)")
    return result.stdout
  }

  private static func edit(_ yaml: String, in scratch: URL, env: [String: String] = env) throws
    -> CLIResult
  {
    let file = scratch.appending(path: "workspace.yaml")
    try yaml.write(to: file, atomically: true, encoding: .utf8)
    return try run(
      ["ws", "edit", "-F", file.path, "--approved", "Edit the Acme fixture"],
      in: scratch, env: env)
  }

  private static func run(
    _ args: [String], in scratch: URL, cwd: URL? = nil, env: [String: String] = env
  ) throws -> CLIResult {
    try SiltaBinary.run(scoped + args, in: scratch, cwd: cwd, environment: env)
  }
}
