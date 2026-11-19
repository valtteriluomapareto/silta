import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension BodyInputCommandTests {
  enum Route: String, CaseIterable {
    case taskPlan, taskEdit, fromPlan, workspaceEdit, docEdit, docPropose

    var command: String {
      switch self {
      case .taskPlan: "task plan"
      case .taskEdit: "task edit"
      case .fromPlan: "task from-plan"
      case .workspaceEdit: "ws edit"
      case .docEdit: "doc edit"
      case .docPropose: "doc propose"
      }
    }

    var usesDocs: Bool {
      self == .docEdit || self == .docPropose
    }

    func arguments(_ source: String) -> [String] {
      let command = command.split(separator: " ").map(String.init)
      return ["--ws", "acme"] + command + tail(source)
    }

    private func tail(_ source: String) -> [String] {
      switch self {
      case .taskPlan, .taskEdit:
        ["AC-1", "-F", source]
      case .fromPlan:
        [source, "--dry-run"]
      case .workspaceEdit:
        ["-F", source, "--approved", "Update Acme configuration"]
      case .docEdit:
        ["rules", "-F", source, "--approved", "Update Acme rules"]
          + DocEditCommandTests.creation
      case .docPropose:
        ["rules", "-F", source, "-m", "Share the rule"] + DocEditCommandTests.creation
      }
    }
  }

  @Test(arguments: Route.allCases)
  func eachReaderRefusesOverLimitWithActualCommandHelp(route: Route) throws {
    try withScratchDirectory { scratch in
      let store =
        try route.usesDocs
        ? AcmeDocAttachments.make(in: scratch) : Self.setupPlan(in: scratch)
      let source = scratch.appending(path: "private Acme filename")
      try Self.oversizedPlan().write(to: source)
      let before = try Self.storedInput(in: store)
      let args = route.arguments(source.path)
      let json = try SiltaBinary.run(
        args + ["--json"], in: scratch, environment: TaskCommandTests.fixed)
      let text = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      let error = try GuideContractTests.object(json.stdout)["error"] as? [String: Any]
      let help = "silta --ws 'acme' " + route.command + " --help"
      let after = try Self.storedInput(in: store)
      withKnownIssue("#268: each raw body reader has its own limit or recovery") {
        #expect(json.termination == .exit(1) && text.termination == .exit(1))
        #expect(json.stderr.isEmpty && text.stdout.isEmpty)
        #expect(error?["code"] as? String == "invalid")
        #expect(error?["next"] as? [String] == [help])
        #expect(error?["next_by"] as? String == "agent")
        #expect(error?["message"] as? String == "Body input exceeds 65536 bytes.")
        #expect(text.stderr.contains("next: " + help))
        #expect(!json.stdout.contains(source.path) && !text.stderr.contains(source.path))
        #expect(after == before)
      }
    }
  }

  @Test func aRegularSymlinkAndAnExactCapStdinBodyAreAccepted() throws {
    try withScratchDirectory { scratch in
      _ = try AcmeDocAttachments.make(in: scratch)
      let source = scratch.appending(path: "source")
      let link = scratch.appending(path: "regular alias")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
      let body = String(repeating: "é", count: Self.maximumBytes / 2)
      try Data(body.utf8).write(to: source)
      let run = try SiltaBinary.run(
        Route.docPropose.arguments(link.path) + ["--json"], in: scratch,
        environment: TaskCommandTests.fixed)
      try #require(run.termination == .exit(0), "\(run.stdout)")
      let other =
        [
          "--ws", "acme", "doc", "propose", "other-rules", "-F", "-", "-m", "Share another rule",
          "--json",
        ] + DocEditCommandTests.creation
      let pipe = #"source=$1; binary=$2; shift 2; /bin/cat "$source" | "$binary" "$@""#
      let stdin = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        ["-c", pipe, "_", source.path, try SiltaBinary.url().path] + other,
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(stdin.termination == .exit(0), "\(stdin.stdout)")
    }
  }

  @Test func authorizationStillWinsBeforeWorkspaceInput() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setupPlan(in: scratch)
      let source = scratch.appending(path: "large.yaml")
      try Self.oversizedPlan().write(to: source)
      let before = try Self.storedInput(in: store)
      let result = try SiltaBinary.run(
        ["--ws", "acme", "ws", "edit", "-F", source.path, "--json"],
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(3))
      #expect(try TaskStateRegressionTests.error(result)["code"] as? String == "human_only")
      #expect(try Self.storedInput(in: store) == before)
    }
  }

  private static func storedInput(in store: DatabaseStore) throws -> [String] {
    try store.read { db in
      try String.fetchAll(db, sql: "SELECT plan_md FROM task WHERE plan_md IS NOT NULL ORDER BY id")
        + ["task", "workspace", "doc", "doc_rev", "approval"].map { table in
          String(try Int.fetchOne(db, sql: "SELECT count(*) FROM " + table) ?? 0)
        }
    }
  }
}
