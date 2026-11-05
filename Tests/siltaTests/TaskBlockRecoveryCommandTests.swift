import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct TaskBlockRecoveryCommandTests {
  @Test func approvedRetryReplaysTheNamedBlock() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(
          args + ["--deterministic", "--json"], in: scratch,
          environment: TaskBlockCommandTests.environment)
      }
      for title in ["Acme first", "Acme second"] {
        #expect(try run(["task", "add", title, "--start"]).termination == .exit(0))
      }
      let refusal = try run([
        "task", "block", "AC-1", "--on", "AC-2", "ext:acme",
        "--follow-up", "3d", "--allow-secret", "-m", "Acme answer",
      ])
      #expect(refusal.termination == .exit(3))
      let object = try #require(
        try JSONSerialization.jsonObject(with: Data(refusal.stdout.utf8)) as? [String: Any])
      let error = try #require(object["error"] as? [String: Any])
      let retry = try #require((error["next"] as? [String])?.first)
      let file = scratch.appending(path: "answer.md")
      try Data("Acme answer".utf8).write(to: file)
      let binary = try SiltaBinary.url()
      let shell =
        retry.replacingOccurrences(of: "silta ", with: shellWord(binary.path) + " ")
        .replacingOccurrences(of: "<file>", with: shellWord(file.path))
        .replacingOccurrences(of: "<the human's words>", with: "Keep this Acme answer.")
        + " --deterministic --json"
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"), ["-c", shell],
        in: scratch, environment: TaskBlockCommandTests.environment)
      #expect(result.termination == .exit(0))
      let show = try run(["task", "show", "AC-1"])
      #expect(show.stdout.contains("\"follow_up_at\":\"2023-11-17\""))
      #expect(show.stdout.contains("ext:acme") && show.stdout.contains("task:AC-2"))
      try store.read { db in
        let commands = try String.fetchAll(db, sql: "SELECT command FROM approval")
        #expect(commands.count == 1 && commands[0].contains("ext:acme"))
        #expect(commands[0].contains("--follow-up '3d'") && !commands[0].contains("Acme answer"))
      }
    }
  }
}
