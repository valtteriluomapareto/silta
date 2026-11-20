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

    func arguments(_ source: String, workspace: String = "acme") -> [String] {
      let command = command.split(separator: " ").map(String.init)
      return ["--ws", workspace] + command + tail(source)
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
      if route.usesDocs { try AcmeDocAttachments.attach("rules", to: "service", in: store) }
      let source = scratch.appending(path: "private Acme filename")
      try Self.oversizedPlan().write(to: source)
      let before = try Self.storedInput(in: store)
      let args = route.arguments(source.path)
      let json = try SiltaBinary.run(
        args + ["--json"], in: scratch, environment: TaskCommandTests.fixed)
      let text = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      let error = try GuideContractTests.object(json.stdout)["error"] as? [String: Any]
      let help = "silta --ws 'acme' " + route.command + " --help"
      let next =
        route == .taskEdit
        ? ["silta --ws 'acme' task edit 'AC-1' --print", help] : [help]
      let after = try Self.storedInput(in: store)
      #expect(json.termination == .exit(1) && text.termination == .exit(1))
      #expect(json.stderr.isEmpty && text.stdout.isEmpty)
      #expect(error?["code"] as? String == "invalid")
      #expect(error?["next"] as? [String] == next)
      #expect(error?["next_by"] as? String == "agent")
      #expect(error?["message"] as? String == "Body input exceeds 65536 bytes.")
      #expect(text.stderr.contains("next: " + help))
      #expect(!json.stdout.contains(source.path) && !text.stderr.contains(source.path))
      #expect(after == before)
      try EditorCommandTests.followRecovery(json.stdout, in: scratch)
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
      #expect(try TaskStateCommandTests.error(result)["code"] as? String == "human_only")
      #expect(try Self.storedInput(in: store) == before)
    }
  }

  @Test func invalidUtf8AndDocumentNulRefuseWithoutAnApprovalRecord() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let source = scratch.appending(path: "raw body")
      let before = try Self.storedInput(in: store)
      for (bytes, message) in [
        (Data([0xc3]), "Body input must be valid UTF-8."),
        (Data("Acme\u{0}tail".utf8), "Doc input must not contain NUL bytes."),
      ] {
        try bytes.write(to: source)
        let result = try SiltaBinary.run(
          Route.docEdit.arguments(source.path) + ["--json"], in: scratch,
          environment: TaskCommandTests.fixed)
        #expect(result.termination == .exit(1))
        let error = try TaskStateCommandTests.error(result)
        #expect(error["message"] as? String == message)
        #expect(try Self.storedInput(in: store) == before)
      }
    }
  }

  @Test func existingLargePlansStillRoundTripThroughTheEditor() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setupPlan(in: scratch)
      let large = try #require(String(data: Self.oversizedPlan(), encoding: .utf8))
      let saved = try SiltaBinary.run(
        ["--ws", "acme", "task", "plan", "AC-1", "-m", large], in: scratch,
        environment: TaskCommandTests.actor)
      try #require(saved.termination == .exit(0))
      let before = try Self.storedInput(in: store)
      let savedPlan = try store.read { try String.fetchOne($0, sql: "SELECT plan_md FROM task") }
      #expect(savedPlan == large)
      let output = try EditorTerminalFixture.run(
        EditorCommandTests.taskEdit + ["--json"], in: scratch,
        environment: TaskCommandTests.actor.merging(["EDITOR": "/usr/bin/true"]) { _, new in new })
      #expect(output.result.termination == .exit(0), "\(output.result.stdout)")
      #expect(try Self.storedInput(in: store) == before)
    }
  }

  @Test func unsafeWorkspaceNamesDoNotEnterBodyRecoveryHints() throws {
    try withScratchDirectory { scratch in
      _ = try AcmeDocAttachments.make(in: scratch)
      let source = scratch.appending(path: "absent input")
      let cases = [
        ("acme\nfixture", Route.workspaceEdit),
        ("AKIA" + String(repeating: "0", count: 16), Route.docPropose),
      ]
      for (scope, route) in cases {
        let command = route.arguments(source.path, workspace: scope)
        let help = "silta " + route.command + " --help"
        let json = try SiltaBinary.run(
          command + ["--json"], in: scratch, environment: TaskCommandTests.fixed)
        let text = try SiltaBinary.run(command, in: scratch, environment: TaskCommandTests.fixed)
        #expect(json.termination == .exit(1) && text.termination == .exit(1))
        let error = try TaskStateCommandTests.error(json)
        #expect(error["code"] as? String == "invalid")
        #expect(error["next"] as? [String] == [help])
        #expect(text.stderr.contains("next: " + help))
        #expect(!text.stderr.contains(scope) && !json.stdout.contains(scope))
        try EditorCommandTests.followRecovery(json.stdout, in: scratch)
      }
    }
  }

  private static func storedInput(in store: DatabaseStore) throws -> [String] {
    try store.read { db in
      try ["task", "task_plan_rev", "workspace", "doc", "doc_rev", "approval"].flatMap { table in
        try Row.fetchAll(db, sql: "SELECT * FROM " + table + " ORDER BY id").map(\.description)
      }
    }
  }
}
