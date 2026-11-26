import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct TaskBlockReplacementCommandTests {
  @Test func swapChecksOnlyTheFinalBlockerSet() throws {
    try withScratchDirectory { scratch in
      let store = try setup(scratch)
      let result = try run(
        [
          "task", "block", "AC-1", "--off", "ext:old", "--on", "ext:new",
          "--follow-up", "3d", "-m", "Ask the new Acme party",
        ], scratch)
      withKnownIssue("SI-261: block cannot replace an external blocker") {
        let data = try TaskStateCommandTests.data(result)
        let waiting = try #require(data["waiting"] as? [String: Any])
        #expect(waiting["on"] as? [String] == ["ext:new", "task:AC-2"])
        #expect(waiting["ready"] as? Bool == false)
        #expect(waiting["why"] as? String == "Ask the new Acme party")
        #expect(data["follow_up_at"] as? String == "2023-11-17")
        #expect(result.stdout.contains("new_party"))
        #expect(try approvals(store).isEmpty)
        let shown = try run(["task", "show", "AC-1", "--timeline"], scratch)
        #expect(shown.stdout.contains(#""on":["ext:new","task:AC-2"]"#))
      }
    }
  }

  @Test func makingABlockReadyRequiresAnActuallyUsedApproval() throws {
    try withScratchDirectory { scratch in
      let store = try setup(scratch)
      let show = ["task", "show", "AC-1", "--timeline"]
      let before = try run(show, scratch)
      let reason = "Acme is no longer waiting on the party"
      let refused = try run(
        ["task", "block", "AC-1", "--off", "ext:old", "--follow-up", "3d", "-m", reason],
        scratch)
      withKnownIssue("SI-261: removal can neither gate readiness nor generate its retry") {
        let error = try TaskStateCommandTests.error(refused)
        #expect(refused.termination == .exit(3))
        #expect(error["code"] as? String == "human_only")
        #expect(error["next_by"] as? String == "human")
        #expect((error["message"] as? String)?.contains("ext:old") == true)
        #expect((error["message"] as? String)?.contains("ready") == true)
        #expect(!refused.stdout.contains(reason))
        #expect(try run(show, scratch) == before)
        #expect(try approvals(store).isEmpty)
        let next = try #require(error["next"] as? [String])
        let command = try #require(next.first)
        #expect(command.hasPrefix("silta --ws 'acme' task block 'AC-1' --off 'ext:old'"))
        #expect(command.contains("--follow-up '3d' -F - "))

        let retry = try approvedRetry(command, reason: reason, scratch: scratch)
        let data = try TaskStateCommandTests.data(retry)
        let waiting = try #require(data["waiting"] as? [String: Any])
        #expect(data["status"] as? String == "blocked")
        #expect(waiting["ready"] as? Bool == true)
        #expect(waiting["on"] as? [String] == ["task:AC-2"])
        #expect(!retry.stdout.contains("approval_unused"))
        let audit = try approvals(store)
        #expect(audit.count == 1 && audit.first?.contains("--off 'ext:old'") == true)
        #expect(audit.first?.contains(reason) == false)
      }
    }
  }

  @Test(arguments: [false, true])
  func emptyBlockIsUnreadyAndTerminalBlockerCanBeRemoved(dropped: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try setup(scratch, dropped: dropped)
      let result = try run(
        [
          "task", "block", "AC-1", "--off", "ext:old", "AC-2", "--off", "task:AC-2",
          "--follow-up", "3d", "-m", "Wait for the Acme answer",
        ], scratch)
      withKnownIssue("SI-261: named links cannot be removed to leave an answer-only block") {
        let data = try TaskStateCommandTests.data(result)
        let waiting = try #require(data["waiting"] as? [String: Any])
        #expect(waiting["on"] as? [String] == [])
        #expect(waiting["ready"] as? Bool == false)
        #expect(data["status"] as? String == "blocked")
        let unblock = try run(["task", "unblock", "AC-1"], scratch)
        #expect(try TaskStateCommandTests.error(unblock)["code"] as? String == "human_only")
      }
    }
  }

  @Test func readinessAndSecretRetentionRecordOneApproval() throws {
    try withScratchDirectory { scratch in
      let store = try setup(scratch)
      let result = try run(
        [
          "task", "block", "AC-1", "--off", "ext:old", "--allow-secret",
          "--approved", "Accept the Acme correction.", "-m", "Pwd=acme-synthetic-value",
        ],
        scratch)
      withKnownIssue("SI-261: the combined readiness and secret approval is unavailable") {
        let data = try TaskStateCommandTests.data(result)
        #expect((data["waiting"] as? [String: Any])?["ready"] as? Bool == true)
        #expect(!result.stdout.contains("approval_unused"))
        #expect(!result.stdout.contains("acme-synthetic-value"))
        let audit = try approvals(store)
        #expect(audit.count == 1 && audit.first?.contains("--allow-secret") == true)
        #expect(audit.first?.contains("acme-synthetic-value") == false)
      }
    }
  }

  @Test func invalidRemovalLeavesTheOriginalBlock() throws {
    try withScratchDirectory { scratch in
      let store = try setup(scratch)
      try success(["task", "add", "Acme active", "--start"], scratch)
      let show = ["task", "show", "AC-1", "--timeline"]
      let before = try run(show, scratch)
      for args in [
        ["AC-1", "--off", "ext:old", "ext:absent"],
        ["AC-1", "--off", "ext:old", "--on", "ext:old"],
        ["AC-3", "--off", "ext:old"],
      ] {
        let result = try run(["task", "block"] + args + ["-m", "Acme correction"], scratch)
        withKnownIssue("SI-261: unsupported --off cannot validate a blocker correction") {
          let error = try TaskStateCommandTests.error(result)
          #expect(error["code"] as? String == "invalid")
          if args.contains("ext:absent") {
            #expect((error["message"] as? String)?.contains("ext:old") == true)
            #expect(error["next"] as? [String] == ["silta --ws 'acme' task show 'AC-1'"])
          }
        }
      }
      #expect(try run(show, scratch) == before)
      #expect(try approvals(store).isEmpty)
    }
  }

  private func setup(_ scratch: URL, dropped: Bool = false) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(scratch)
    for title in ["Acme waiting", "Acme dependency"] {
      try success(["task", "add", title, "--start"], scratch)
    }
    try success(
      ["task", "block", "AC-1", "--on", "AC-2", "ext:old", "-m", "Old Acme reason"], scratch)
    try success(
      ["task", dropped ? "drop" : "done", "AC-2", "-m", "Acme dependency settled"], scratch)
    return store
  }

  private func approvals(_ store: DatabaseStore) throws -> [String] {
    try store.read { try String.fetchAll($0, sql: "SELECT command FROM approval ORDER BY id") }
  }

  private func run(_ args: [String], _ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      args + ["--deterministic", "--json"], in: scratch,
      environment: TaskBlockCommandTests.environment)
  }

  private func success(_ args: [String], _ scratch: URL) throws {
    let result = try run(args, scratch)
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
  }

  private func approvedRetry(_ command: String, reason: String, scratch: URL) throws -> CLIResult {
    let body = scratch.appending(path: "reason.txt")
    try reason.write(to: body, atomically: true, encoding: .utf8)
    let shell =
      command
      .replacingOccurrences(of: "silta ", with: shellWord(try SiltaBinary.url().path) + " ")
      .replacingOccurrences(of: "<the human's words>", with: "Accept the Acme correction.")
      + " --deterministic --json < " + shellWord(body.path)
    return try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"), ["-ec", shell], in: scratch,
      environment: TaskBlockCommandTests.environment)
  }
}
