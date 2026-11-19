import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct EditorCommandTests {
  static let taskEdit = ["--ws", "acme", "task", "edit", "AC-1"]
  static let wsEdit = ["ws", "edit", "acme", "--approved", "yes, update Acme fixture"]

  @Test(arguments: [Self.taskEdit, Self.wsEdit])
  func editorWithoutATerminalRefusesWithOneEnvelope(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      try Self.seed(scratch)
      let result = try SiltaBinary.run(
        arguments + ["--json"], in: scratch, environment: Self.editor("echo"))
      withKnownIssue("#256: a nonterminal editor invocation runs the child") {
        #expect(result.termination == .exit(1))
        #expect(result.stdout.split(whereSeparator: \.isNewline).count == 1)
        #expect(result.stdout.contains(#""code":"usage""#))
        #expect(result.stdout.contains("-F"))
        #expect(result.stderr.isEmpty)
      }
    }
  }

  @Test(arguments: [Self.taskEdit, Self.wsEdit])
  func unlaunchableEditorIsAnErrorOnATerminal(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      try Self.seed(scratch)
      let editor = scratch.appending(path: "missing-editor").path
      let output = try EditorTerminalFixture.run(
        arguments + ["--json"], in: scratch, environment: Self.editor(editor))
      withKnownIssue("#256: failed shell exec reports unchanged success") {
        #expect(output.result.termination == .exit(9))
        #expect(output.result.stdout.contains(#""code":"env""#))
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
      let file = scratch.appending(path: "workspace.yaml")
      try configuration.stdout.write(to: file, atomically: true, encoding: .utf8)
      let output = try SiltaBinary.run(
        Self.wsEdit + ["-F", file.path, "--json"], in: scratch, environment: env)
      #expect(output.termination == .exit(0))
      withKnownIssue("#256: unchanged workspace claims to have used approval") {
        #expect(output.stdout.contains("approval_unused"))
      }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
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
