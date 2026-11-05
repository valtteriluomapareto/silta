import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RestoreCommandTests {
  static let agent = ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:40:00.000Z"]

  /// Seeds Acme with AC-1, exports it to `work/out/acme`, then adds AC-2, which a
  /// restore of that export removes.
  static func exported(_ scratch: URL) throws {
    try ExportCommandTests.seed(scratch)
    let export = try SiltaBinary.run(["--ws", "acme", "export", "--to", "out"], in: scratch)
    #expect(export.termination == .exit(0), "\(export.stderr)")
    let add = try SiltaBinary.run(
      ["--ws", "acme", "task", "add", "Later work", "--app", "none"], in: scratch,
      environment: agent)
    #expect(add.termination == .exit(0), "\(add.stderr)")
  }

  static func masked(_ text: String, _ scratch: URL) -> String {
    ExportCommandTests.masked(text, scratch)
      .replacing(/manifest(_sha256)?(":"| )[0-9a-f]{12,64}/) {
        "manifest\($0.output.1 ?? "")\($0.output.2)<sha>"
      }
      .replacing(/before-restore-[0-9]+/) { _ in "before-restore-<ms>" }
  }

  @Test func agentNeedsTheHumanButMayDryRun() throws {
    try withScratchDirectory { scratch in
      try Self.exported(scratch)
      let refused = try SiltaBinary.run(
        ["restore", "out/acme"], in: scratch, environment: Self.agent)
      #expect(refused.termination == .exit(3))
      Golden.forTests().check(Self.masked(refused.stderr, scratch), "restore-refused.txt")
      for json in [false, true] {
        let dry = try SiltaBinary.run(
          ["restore", "out/acme", "--dry-run"] + (json ? ["--json"] : []), in: scratch,
          environment: Self.agent)
        #expect(dry.termination == .exit(0), "\(dry.stderr)")
        Golden.forTests().check(
          Self.masked(dry.stdout, scratch), json ? "restore-dry-run.json" : "restore-dry-run.txt")
      }
      let show = try SiltaBinary.run(["--ws", "acme", "task", "show", "AC-2"], in: scratch)
      #expect(show.termination == .exit(0))
    }
  }

  /// Every line a human is shown before approving: changed tasks, other rows,
  /// settings and claims.
  @Test func dryRunShowsWhatTheHumanApproves() throws {
    try withScratchDirectory { scratch in
      try Self.exported(scratch)
      let queue = try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path)
      try queue.write { db in
        try db.execute(sql: #"UPDATE workspace SET settings='{"review_gate":"any"}'"#)
        try db.execute(
          sql: "UPDATE task SET title='Renamed', claimed_by='agent:claude:other' WHERE seq=1")
        try db.execute(
          sql:
            """
            INSERT INTO service(uid,workspace_id,slug,name)
            VALUES('01HZSVCLATER',1,'later','Later')
            """
        )
      }
      let dry = try SiltaBinary.run(
        ["restore", "out/acme", "--dry-run"], in: scratch, environment: Self.agent)
      #expect(dry.termination == .exit(0), "\(dry.stderr)")
      Golden.forTests().check(Self.masked(dry.stdout, scratch), "restore-dry-run-changes.txt")
    }
  }

  @Test func approvedRestoreReplacesTheWorkspace() throws {
    try withScratchDirectory { scratch in
      try Self.exported(scratch)
      let result = try SiltaBinary.run(
        ["restore", "out/acme", "--approved", "yes, restore acme"], in: scratch,
        environment: Self.agent)
      #expect(result.termination == .exit(0), "\(result.stderr)")
      Golden.forTests().check(Self.masked(result.stdout, scratch), "restore.txt")
      let show = try SiltaBinary.run(["--ws", "acme", "task", "show", "AC-2"], in: scratch)
      #expect(show.termination == .exit(2))
    }
  }

  /// A machine move: export on one home, restore into an empty one, keep working there.
  @Test func restoresIntoAnotherHome() throws {
    try withScratchDirectory { scratch in
      try Self.exported(scratch)
      let other = Self.agent.merging(
        ["SILTA_HOME": scratch.appending(path: "other-home").path]) { $1 }
      let restore = try SiltaBinary.run(
        ["restore", "out/acme", "--json", "--approved", "yes, move acme here"], in: scratch,
        environment: other)
      #expect(restore.termination == .exit(0), "\(restore.stdout)")
      #expect(restore.stdout.contains(#""created":true"#))
      let show = try SiltaBinary.run(
        ["--ws", "acme", "task", "show", "AC-1"], in: scratch, environment: other)
      #expect(show.termination == .exit(0), "\(show.stderr)")
      let added = try SiltaBinary.run(
        ["--ws", "acme", "task", "add", "Next", "--app", "none"], in: scratch,
        environment: other)
      #expect(added.termination == .exit(0), "\(added.stderr)")
      #expect(added.stdout.hasPrefix("AC-2"), "\(added.stdout)")
    }
  }

  @Test(arguments: ["~/out/acme", "~"])
  func unexpandedTildeIsRefused(_ path: String) throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["restore", path, "--dry-run", "--json"], in: scratch)
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains(#""code":"invalid""#))
    }
  }

  /// A damaged tree is refused with a command that names the tree's workspace; followed
  /// with another workspace current, it re-exports the right one.
  @Test func damagedTreeRecoveryNamesTheTreesWorkspace() throws {
    try withScratchDirectory { scratch in
      try Self.exported(scratch)
      try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path).write { db in
        try db.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix)
            VALUES('01HZOTHR00000000000000WS02','other','Other','OT')
            """)
      }
      let use = try SiltaBinary.run(["ws", "use", "other"], in: scratch)
      #expect(use.termination == .exit(0), "\(use.stderr)")
      try Data("tampered\n".utf8).write(
        to: scratch.appending(path: "work/out/acme/tasks/AC-1.md"))
      let refused = try SiltaBinary.run(["restore", "out/acme", "--dry-run"], in: scratch)
      #expect(refused.termination == .exit(1))
      let recovery = try #require(
        refused.stderr.split(separator: "\n").first {
          $0.hasPrefix("ask human: ") || $0.hasPrefix("next: ")
        })
      let command =
        recovery
        .replacingOccurrences(of: "ask human: ", with: "")
        .replacingOccurrences(of: "next: ", with: "")
      let path = try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
      let followed = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", command], in: scratch,
        environment: ["PATH": path])
      #expect(followed.termination == .exit(0), "\(followed.stderr)")
      let manifest = scratch.appending(path: "silta-home/exports/acme/manifest.json")
      #expect(
        try String(contentsOf: manifest, encoding: .utf8).contains(#""workspace": "acme""#))
    }
  }

  /// The dry run shows the task counter, so the human sees future refs move.
  @Test func dryRunShowsTheTaskCounter() throws {
    try withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      try Self.setCounter(scratch, to: 50)
      let export = try SiltaBinary.run(["--ws", "acme", "export", "--to", "out"], in: scratch)
      #expect(export.termination == .exit(0), "\(export.stderr)")
      try Self.setCounter(scratch, to: 2)
      let dry = try SiltaBinary.run(
        ["restore", "out/acme", "--dry-run"], in: scratch, environment: Self.agent)
      #expect(dry.termination == .exit(0), "\(dry.stderr)")
      Golden.forTests().check(Self.masked(dry.stdout, scratch), "restore-dry-run-counter.txt")
      try Self.setCounter(scratch, to: 100)
      let kept = try SiltaBinary.run(
        ["restore", "out/acme", "--dry-run", "--json"], in: scratch, environment: Self.agent)
      #expect(kept.termination == .exit(0), "\(kept.stderr)")
      Golden.forTests().check(
        Self.masked(kept.stdout, scratch), "restore-dry-run-counter-kept.json")
    }
  }

  /// A prefix change is a ref change even while the counter stays put.
  @Test func dryRunShowsAPrefixChange() throws {
    try withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      try Self.setCounter(scratch, to: 50)
      let export = try SiltaBinary.run(["--ws", "acme", "export", "--to", "out"], in: scratch)
      #expect(export.termination == .exit(0), "\(export.stderr)")
      try Self.setPrefix(scratch, to: "AX")
      try Self.setCounter(scratch, to: 100)
      let dry = try SiltaBinary.run(
        ["restore", "out/acme", "--dry-run"], in: scratch, environment: Self.agent)
      #expect(dry.termination == .exit(0), "\(dry.stderr)")
      Golden.forTests().check(Self.masked(dry.stdout, scratch), "restore-dry-run-prefix.txt")
      let json = try SiltaBinary.run(
        ["restore", "out/acme", "--dry-run", "--json"], in: scratch, environment: Self.agent)
      #expect(json.termination == .exit(0), "\(json.stderr)")
      Golden.forTests().check(Self.masked(json.stdout, scratch), "restore-dry-run-prefix.json")
    }
  }

  static func setPrefix(_ scratch: URL, to prefix: String) throws {
    try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path).write { db in
      try db.execute(
        sql: "UPDATE workspace SET task_prefix=? WHERE slug='acme'", arguments: [prefix])
    }
  }

  static func setCounter(_ scratch: URL, to next: Int) throws {
    try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path).write { db in
      try db.execute(
        sql: """
          UPDATE seq_counter SET next=?
          WHERE scope='task:'||(SELECT id FROM workspace WHERE slug='acme')
          """, arguments: [next])
    }
  }
}
