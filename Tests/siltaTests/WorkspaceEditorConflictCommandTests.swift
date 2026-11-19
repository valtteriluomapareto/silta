import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceEditorConflictCommandTests {
  @Test(arguments: [false, true])
  func competingSaveKeepsTheAttemptInAPrivateFile(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let original = "workspace: {slug: acme, name: Acme, task_prefix: AC}\n"
      let attempted = original.replacingOccurrences(of: "name: Acme", with: "name: Edited")
      let editor = try Self.editor(in: scratch, original: original, attempted: attempted)
      let env = TaskCommandTests.actor.merging(["EDITOR": editor]) { _, value in value }
      let args = EditorCommandTests.wsEdit + (json ? ["--json"] : [])
      let run = try EditorTerminalFixture.run(args, in: scratch, environment: env)
      #expect(run.result.termination == .exit(6))
      let path = try String(contentsOf: scratch.appending(path: "edited-path"), encoding: .utf8)
      let buffer = URL(filePath: path)
      let directory = buffer.deletingLastPathComponent()
      defer {
        try? FileManager.default.removeItem(at: directory)  // fixture cleanup
      }
      #expect(try String(contentsOf: buffer, encoding: .utf8) == attempted)
      let attributes = try FileManager.default.attributesOfItem(
        atPath: directory.path)
      #expect(attributes[.posixPermissions] as? Int == 0o700)
      let other = try store.read { try String.fetchOne($0, sql: "SELECT slug FROM service") }
      #expect(other == "mailer")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
      if json {
        let normalized = run.result.stdout.replacingOccurrences(of: path, with: "<buffer>")
        Golden.forTests().check(normalized, "ws-edit-stale.json")
        try EditorCommandTests.followRecovery(run.result.stdout, in: scratch)
      } else {
        let lines = run.terminal.split(whereSeparator: \.isNewline)
          .filter { $0.hasPrefix("error:") || $0.hasPrefix("next:") }
          .joined(separator: "\n").replacingOccurrences(of: path, with: "<buffer>")
        Golden.forTests().check(lines + "\n", "ws-edit-stale.txt")
      }
    }
  }

  @Test(arguments: [false, true])
  func unchangedInvalidYAMLNamesRunnableRecovery(json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let marker = shellWord(scratch.appending(path: "initial-edit").path)
      let script = scratch.appending(path: "invalid-editor.sh")
      let body = """
        if [ ! -f \(marker) ]; then
          printf '%s\n' 'workspace: [' > "$1"
          : > \(marker)
        fi
        """
      try body.write(to: script, atomically: true, encoding: .utf8)
      var env = TaskCommandTests.actor
      env["EDITOR"] = "/bin/sh " + shellWord(script.path)
      let args = EditorCommandTests.wsEdit + (json ? ["--json"] : [])
      let run = try EditorTerminalFixture.run(args, in: scratch, environment: env)
      #expect(run.result.termination == .exit(1))
      if json {
        #expect(run.result.stdout.contains(#""code":"invalid""#))
        #expect(run.result.stdout.contains(#""next_by":"agent""#))
        try EditorCommandTests.followRecovery(run.result.stdout, in: scratch)
      } else {
        #expect(run.result.stdout.isEmpty)
        #expect(run.terminal.contains("[invalid]"))
        #expect(run.terminal.contains("next: silta --ws 'acme' ws show"))
      }
    }
  }

  private static func editor(in scratch: URL, original: String, attempted: String) throws -> String
  {
    let competing = scratch.appending(path: "competing.yaml")
    let proposal = scratch.appending(path: "proposal.yaml")
    let capture = scratch.appending(path: "edited-path")
    let script = scratch.appending(path: "workspace-editor.sh")
    try (original + "services: [mailer]\n").write(to: competing, atomically: true, encoding: .utf8)
    try attempted.write(to: proposal, atomically: true, encoding: .utf8)
    let body = """
      set -e
      \(shellWord(try SiltaBinary.url().path)) ws edit acme -F \(shellWord(competing.path)) \
        --approved 'yes, save the competing Acme fixture'
      printf '%s' "$1" > \(shellWord(capture.path))
      cp \(shellWord(proposal.path)) "$1"
      """
    try body.write(to: script, atomically: true, encoding: .utf8)
    return "/bin/sh " + shellWord(script.path)
  }
}
