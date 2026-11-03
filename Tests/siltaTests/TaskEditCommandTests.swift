import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskEditCommandTests {
  private static func document(_ data: [String: Any], title: String) -> String {
    [
      ("Title", title), ("Description", data["description"] as? String ?? ""),
      ("Acceptance", data["acceptance"] as? String ?? ""),
      ("Plan", data["plan"] as? String ?? ""), ("Result", data["result"] as? String ?? ""),
    ]
    .map { "## \($0.0)\n~~~\n\($0.1)\n~~~\n" }.joined()
  }

  @Test func showFileStdinAndEditorPreserveAcceptanceAndCleanUp() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let env = TaskCommandTests.actor
      #expect(
        try SiltaBinary.run(
          ["task", "add", "Acme", "--start"], in: scratch,
          environment: env
        ).termination == .exit(0))
      try store.write { tx in
        try tx.database.execute(sql: "UPDATE task SET acceptance_md='Keep Acme acceptance'")
      }
      let shown = try SiltaBinary.run(
        ["task", "show", "AC-1", "--json"], in: scratch,
        environment: env)
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any])
      let data = try #require(object["data"] as? [String: Any])
      #expect(data["acceptance"] as? String == "Keep Acme acceptance")
      let file = scratch.appending(path: "edit.md")
      try Self.document(data, title: "Acme file").write(to: file, atomically: true, encoding: .utf8)
      let edited = try SiltaBinary.run(
        [
          "task", "edit", "AC-1", "-F", file.path,
          "--approved", "Unused words", "--json",
        ], in: scratch, environment: env)
      #expect(edited.termination == .exit(0))
      #expect(edited.stdout.contains("approval_unused"))
      let command = "cat \"$2\" | \"$1\" task edit AC-1 -F - --json"
      let stdin = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        ["-c", command, "_", try SiltaBinary.url().path, file.path], in: scratch, environment: env)
      #expect(stdin.termination == .exit(0))
      try Self.document(data, title: "Acme editor").write(
        to: file, atomically: true, encoding: .utf8)
      try Self.editorCheck(scratch, file: file, store: store)
      let acceptance = try store.read {
        try String.fetchOne($0, sql: "SELECT acceptance_md FROM task")
      }
      #expect(acceptance == "Keep Acme acceptance")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }

  private static func editorCheck(_ scratch: URL, file: URL, store: DatabaseStore) throws {
    let script = scratch.appending(path: "editor.sh")
    let capture = scratch.appending(path: "capture.txt")
    try "printf '%s' \"$1\" > \(shellWord(capture.path))\ncp \(shellWord(file.path)) \"$1\"\n"
      .write(to: script, atomically: true, encoding: .utf8)
    var env = TaskCommandTests.actor
    env["EDITOR"] = "/bin/sh " + shellWord(script.path)
    let edited = try SiltaBinary.run(
      ["task", "edit", "AC-1", "--json"], in: scratch, environment: env)
    #expect(edited.termination == .exit(0))
    let temporary = try String(contentsOf: capture, encoding: .utf8)
    #expect(temporary.hasPrefix("/"))
    #expect(!FileManager.default.fileExists(atPath: temporary))
    let title = try store.read { try String.fetchOne($0, sql: "SELECT title FROM task") }
    #expect(title == "Acme editor")
    let before = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task_event") }
    try "printf '%s' \"$1\" > \(shellWord(capture.path))\nprintf ignored > \"$1\"\nexit 2\n"
      .write(to: script, atomically: true, encoding: .utf8)
    #expect(
      try SiltaBinary.run(
        ["task", "edit", "AC-1"], in: scratch,
        environment: env
      ).termination == .exit(0))
    let cancelled = try String(contentsOf: capture, encoding: .utf8)
    #expect(!FileManager.default.fileExists(atPath: cancelled))
    #expect(
      try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task_event") } == before)
  }
}

extension TaskEditCommandTests {
  @Test func invalidAndMissingInputHaveScopedRunnableRecovery() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try SiltaBinary.run(
          ["task", "add", "Acme", "--start"], in: scratch,
          environment: TaskCommandTests.actor
        ).termination == .exit(0))
      let file = scratch.appending(path: "invalid.md")
      try Data([255]).write(to: file)
      for path in [file.path, file.path + "missing"] {
        let result = try SiltaBinary.run(
          [
            "--ws", "acme", "task", "edit", "AC-1", "-F", path,
            "--json",
          ], in: scratch, environment: TaskCommandTests.actor)
        #expect(result.termination == .exit(1))
        #expect(result.stdout.contains("silta --ws 'acme' task edit --help"))
        #expect(result.stdout.contains("silta --ws 'acme' task edit 'AC-1' --print"))
      }
    }
  }
}
