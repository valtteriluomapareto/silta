import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct EditorCommandTests {
  static let taskEdit = ["--ws", "acme", "task", "edit", "AC-1"]
  static let wsEdit = ["ws", "edit", "acme", "--approved", "yes, update Acme fixture"]

  @Test(arguments: [Self.taskEdit, Self.wsEdit], [false, true])
  func editorWithoutATerminalRefusesWithOneEnvelope(arguments: [String], json: Bool) throws {
    try withScratchDirectory { scratch in
      try Self.seed(scratch)
      let result = try SiltaBinary.run(
        arguments + (json ? ["--json"] : []), in: scratch, environment: Self.editor("echo"))
      #expect(result.termination == .exit(1))
      let kind = arguments.contains("task") ? "task" : "ws"
      Golden.forTests().check(
        json ? result.stdout : result.stderr, kind + "-edit-terminal." + (json ? "json" : "txt"))
      if json {
        #expect(result.stdout.split(whereSeparator: \.isNewline).count == 1)
        #expect(result.stderr.isEmpty)
        try Self.followRecovery(result.stdout, in: scratch)
      } else {
        #expect(result.stdout.isEmpty)
      }
    }
  }

  @Test(arguments: [Self.taskEdit, Self.wsEdit], [false, true])
  func unlaunchableEditorIsAnErrorOnATerminal(arguments: [String], json: Bool) throws {
    try withScratchDirectory { scratch in
      try Self.seed(scratch)
      let missing = scratch.appending(path: "missing-editor").path
      for editor in [missing, "unmatched'"] {
        let output = try EditorTerminalFixture.run(
          arguments + (json ? ["--json"] : []), in: scratch, environment: Self.editor(editor))
        #expect(output.result.termination == .exit(9))
        let kind = arguments.contains("task") ? "task" : "ws"
        if json {
          Golden.forTests().check(output.result.stdout, kind + "-edit-launch.json")
          try Self.followRecovery(output.result.stdout, in: scratch)
        } else {
          #expect(output.result.stdout.isEmpty)
          let refusal = output.terminal.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("error:") || $0.hasPrefix("ask human:") }
            .joined(separator: "\n")
          Golden.forTests().check(refusal + "\n", kind + "-edit-launch.txt")
        }
      }
    }
  }

  @Test func unchangedWorkspaceFileReportsUnusedApproval() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let env = Self.editor("echo")
      let configuration = try SiltaBinary.run(
        ["--ws", "acme", "ws", "show"], in: scratch, environment: env)
      try #require(configuration.termination == .exit(0), "\(configuration.stderr)")
      #expect(configuration.stdout.hasPrefix("# silta-base: "))
      let quiet = try SiltaBinary.run(["--ws", "acme", "ws", "show", "--quiet"], in: scratch)
      let json = try SiltaBinary.run(["--ws", "acme", "ws", "show", "--json"], in: scratch)
      #expect(quiet.stdout == configuration.stdout)
      #expect(try TaskStateCommandTests.data(json)["yaml"] as? String == configuration.stdout)
      let file = scratch.appending(path: "workspace.yaml")
      try configuration.stdout.write(to: file, atomically: true, encoding: .utf8)
      let output = try SiltaBinary.run(
        Self.wsEdit + ["-F", file.path, "--json"], in: scratch, environment: env)
      #expect(output.termination == .exit(0))
      #expect(output.stdout.contains("approval_unused"))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func staleWorkspaceSnapshotKeepsTheCurrentConfiguration(unchanged: Bool, indented: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let old = try SiltaBinary.run(["--ws", "acme", "ws", "show"], in: scratch)
      try #require(old.termination == .exit(0), "\(old.stderr)")
      let file = scratch.appending(path: "workspace.yaml")
      let winner = """
        workspace: {slug: acme, name: Acme, task_prefix: AC}
        services: [mailer]

        """
      try winner.write(to: file, atomically: true, encoding: .utf8)
      let edit = Self.wsEdit + ["-F", file.path, "--json"]
      let first = try SiltaBinary.run(edit, in: scratch, environment: TaskCommandTests.actor)
      try #require(first.termination == .exit(0), "\(first.stdout)")
      let draft =
        unchanged ? old.stdout : old.stdout.replacingOccurrences(of: "Acme", with: "Edited")
      try ((indented ? " " : "") + draft).write(to: file, atomically: true, encoding: .utf8)
      let stale = try SiltaBinary.run(edit, in: scratch, environment: TaskCommandTests.actor)
      let currentService = try store.read {
        try String.fetchOne($0, sql: "SELECT slug FROM service")
      }
      let approvalCount = try store.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM approval")
      }
      #expect(stale.termination == .exit(indented ? 1 : 6))
      let error = try TaskStateCommandTests.error(stale)
      #expect(error["code"] as? String == (indented ? "invalid" : "conflict"))
      #expect(error["next"] as? [String] == ["silta --ws 'acme' ws show"])
      try Self.followRecovery(stale.stdout, in: scratch)
      #expect(currentService == "mailer")
      #expect(approvalCount == 1)
    }
  }

  @Test func nonTerminalTaskEditPointsToTheScopedDocument() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','OT')
            """)
      }
      let added = try SiltaBinary.run(
        ["--ws", "other", "task", "add", "Other task", "--start"], in: scratch,
        environment: TaskCommandTests.actor)
      try #require(added.termination == .exit(0), "\(added.stderr)")
      let args = ["--ws", "other", "task", "edit", "OT-1"]
      let json = try SiltaBinary.run(args + ["--json"], in: scratch)
      #expect(json.termination == .exit(1))
      let error = try TaskStateCommandTests.error(json)
      let expected = "silta --ws 'other' task edit 'OT-1' --print"
      #expect(error["next"] as? [String] == [expected])
      try Self.followRecovery(json.stdout, in: scratch)
      let text = try SiltaBinary.run(args, in: scratch)
      #expect(text.termination == .exit(1))
      #expect(text.stderr.contains("next: " + expected))
      let invalid = try SiltaBinary.run(
        ["--ws", "other", "task", "edit", "AC-1", "--json"], in: scratch)
      #expect(
        try TaskStateCommandTests.error(invalid)["next"] as? [String] == [
          "silta --ws 'other' task edit --help"
        ])
    }
  }

  @Test func invalidHomePreservesTheNonTerminalTaskEditUsageError() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(
        Self.taskEdit + ["--json"], in: scratch, environment: ["SILTA_HOME": "relative"])
      #expect(result.termination == .exit(1))
      let error = try TaskStateCommandTests.error(result)
      #expect(error["code"] as? String == "usage")
      #expect(error["next"] as? [String] == ["silta task edit --help"])
      #expect(error["next_by"] as? String == "agent")
    }
  }

  @Test func malformedWorkspaceBaselinesRefuseWithoutMutation() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let shown = try SiltaBinary.run(["ws", "show", "acme"], in: scratch)
      let stamp = try #require(shown.stdout.split(separator: "\n").first)
      let file = scratch.appending(path: "workspace.yaml")
      let yaml = shown.stdout.dropFirst(stamp.count + 1)
      let invalid = [
        "# silta-base: invalid\n" + yaml,
        String(stamp) + "\n" + shown.stdout,
        "# comment\n" + shown.stdout,
      ]
      for draft in invalid {
        try draft.write(to: file, atomically: true, encoding: .utf8)
        let result = try SiltaBinary.run(
          Self.wsEdit + ["-F", file.path, "--json"], in: scratch,
          environment: TaskCommandTests.actor)
        #expect(result.termination == .exit(1))
        let error = try TaskStateCommandTests.error(result)
        #expect(error["code"] as? String == "invalid")
        #expect(error["next"] as? [String] == ["silta --ws 'acme' ws show"])
        try Self.followRecovery(result.stdout, in: scratch)
      }
      #expect(try SiltaBinary.run(["ws", "show", "acme"], in: scratch).stdout == shown.stdout)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }

  static func followRecovery(_ envelope: String, in scratch: URL) throws {
    let json = try #require(
      JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
    let error = try #require(json["error"] as? [String: Any])
    let commands = try #require(error["next"] as? [String])
    try #require(!commands.isEmpty)
    let directory = try SiltaBinary.url().deletingLastPathComponent().path
    let env = TaskCommandTests.actor.merging(["PATH": directory + ":/usr/bin:/bin"]) { _, value in
      value
    }
    for command in commands {
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", command], in: scratch, environment: env)
      #expect(result.termination == .exit(0), "\(result.stderr)")
    }
  }

  private static func seed(_ scratch: URL) throws {
    _ = try TaskCommandTests.setup(scratch)
    let task = try SiltaBinary.run(
      ["--ws", "acme", "task", "add", "Acme task", "--start"], in: scratch,
      environment: TaskCommandTests.actor)
    try #require(task.termination == .exit(0), "\(task.stderr)")
  }

  private static func editor(_ command: String) -> [String: String] {
    TaskCommandTests.actor.merging(["EDITOR": command]) { _, value in value }
  }
}

extension EditorCommandTests {
  @Test func terminalOutputWithNulDoesNotSaveOrRecordApproval() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let added = try SiltaBinary.run(
        ["--ws", "acme", "task", "add", "Acme task", "--start"], in: scratch,
        environment: TaskCommandTests.actor)
      try #require(added.termination == .exit(0))
      let printed = try SiltaBinary.run(Self.taskEdit + ["--print"], in: scratch)
      let original = printed.stdout
      let changed = original.replacingOccurrences(
        of: "## Description\n~~~\n\n", with: "## Description\n~~~\nAcme private\u{0}tail\n")
      try #require(changed != original)
      let edited = scratch.appending(path: "typed body")
      try changed.write(to: edited, atomically: true, encoding: .utf8)
      let args =
        Self.taskEdit + ["--allow-secret", "--approved", "Edit the Acme fixture", "--json"]
      let environment = TaskCommandTests.actor.merging(
        ["EDITOR": "cp " + shellWord(edited.path)]) { _, editor in editor }
      let output = try EditorTerminalFixture.run(args, in: scratch, environment: environment)
      #expect(output.result.termination == .exit(1))
      let error = try TaskStateCommandTests.error(output.result)
      #expect(error["code"] as? String == "invalid")
      #expect(error["message"] as? String == "Body input must not contain NUL bytes.")
      #expect(!output.result.stdout.contains("Acme private"))
      try Self.followRecovery(output.result.stdout, in: scratch)
      #expect(try SiltaBinary.run(Self.taskEdit + ["--print"], in: scratch).stdout == original)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }
}

/// Runs the CLI inside a real pseudoterminal while saving its own stdout and exit.
enum EditorTerminalFixture {
  static func run(_ arguments: [String], in scratch: URL, environment: [String: String]) throws
    -> (result: CLIResult, terminal: String)
  {
    let receipt = scratch.appending(path: "editor-stdout")
    let status = scratch.appending(path: "editor-status")
    let wrapper = #"""
      output=$1
      status=$2
      shift 2
      "$@" > "$output"
      printf '%s\n' "$?" > "$status"
      """#
    let child = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/script"),
      [
        "-q", "/dev/null", "/bin/sh", "-c", wrapper, "silta-test", receipt.path, status.path,
        try SiltaBinary.url().path,
      ] + arguments,
      in: scratch, environment: environment)
    try #require(child.termination == .exit(0), "\(child.stderr)")
    let code = try #require(
      Int32(
        String(contentsOf: status, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    )
    let stdout = try String(contentsOf: receipt, encoding: .utf8)
    return (CLIResult(termination: .exit(code), stdout: stdout, stderr: ""), child.stdout)
  }
}
