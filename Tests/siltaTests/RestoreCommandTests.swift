import Foundation
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
      #expect(added.stdout.contains("AC-2"), "\(added.stdout)")
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
}
