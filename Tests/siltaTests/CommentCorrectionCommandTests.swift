import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

struct CommentCorrectionCommandTests {
  @Test func bodyReadKeepsTheResolvedWorkspace() throws {
    withKnownIssue("#13: reproduce SI-29 round 1 finding") {
      try withScratchDirectory { scratch in
        let store = try CommentHandoffTests.setup(scratch)
        try store.write {
          try $0.database.execute(
            sql:
              "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','OT')"
          )
        }
        let binary = shellWord(try SiltaBinary.url().path)
        let fifo = shellWord(scratch.appending(path: "body.fifo").path)
        let script = """
          mkfifo \(fifo)
          (
            exec 3> \(fifo)
            \(binary) ws use other --json >/dev/null
            printf 'Acme body' >&3
          ) &
          \(binary) comment AC-1 -F \(fifo) --json
          status=$?
          wait
          exit "$status"
          """
        let result = try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"), ["-c", script],
          in: scratch, environment: TaskCommandTests.fixed)
        #expect(result.termination == .exit(0))
        #expect(
          try store.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM comment WHERE task_id=1")
          } == 1)
      }

    }
  }

  @Test func discussionRecoveryAndHistoryRemainDiscoverable() throws {
    withKnownIssue("#13: reproduce SI-29 round 1 finding") {
      try withScratchDirectory { scratch in
        _ = try CommentHandoffTests.setup(scratch)
        func run(_ args: [String], foreign: Bool = false) throws -> CLIResult {

          try SiltaBinary.run(
            args, in: scratch,
            environment: foreign
              ? TaskCommandTests.fixed.merging(["SILTA_ACTOR": "agent:codex:other"]) { $1 }
              : TaskCommandTests.fixed)

        }
        _ = try run([
          "comment", "AC-1", "--kind", "question", "--to", "agent:codex:acme", "-m", "Which API?",
        ])
        _ = try run([
          "comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1", "-m", "Use v2.",
        ])
        let question = try run(["comment", "accept", "AC-1/1", "--json"])
        let failure = try #require(
          try JSONSerialization.jsonObject(with: Data(question.stdout.utf8)) as? [String: Any])
        #expect(
          (failure["error"] as? [String: Any])?["next"] as? [String] == [
            "silta --ws 'acme' task show 'AC-1' --timeline"
          ])
        let data = try TaskStateRegressionTests.data(run(["task", "show", "AC-1", "--json"]))
        let posts = try #require(data["comments"] as? [[String: Any]])
        #expect(posts.first?["answered"] as? Bool == true)
        _ = try run(["comment", "accept", "AC-1/2"])
        let shown = try run(["task", "show", "AC-1"])
        #expect(shown.stdout.contains("1 resolved thread (see --timeline)"))
        let wrong = try run(["comment", "delete", "AC-1/2", "--json"], foreign: true)
        #expect(!wrong.stdout.contains("comment resolve"))
      }

    }
  }
}

extension CommentCorrectionCommandTests {
  @Test(arguments: ["human:acme", "agent:claude:answerer"])
  func onlyAddressedAgentsCountAsAnswered(recipient: String) throws {
    try withScratchDirectory { scratch in
      _ = try CommentHandoffTests.setup(scratch)
      _ = try SiltaBinary.run(
        ["comment", "AC-1", "--kind", "question", "--to", recipient, "-m", "Which API?"],
        in: scratch, environment: TaskCommandTests.fixed)
      _ = try SiltaBinary.run(
        ["comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1", "-m", "Use v2."],
        in: scratch,
        environment: TaskCommandTests.fixed.merging(["SILTA_ACTOR": "agent:claude:answerer"]) { $1 }
      )
      let shown = try SiltaBinary.run(
        ["task", "show", "AC-1"], in: scratch, environment: TaskCommandTests.fixed)
      #expect(shown.stdout.contains("[answered, unresolved]") == (recipient == "agent:claude:answerer"))
    }
  }
}
