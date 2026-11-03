import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ApprovalCommandTests {
  @Test func approvedStealAndForceKeepAgentAttributionAndOneRowPerCall() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      _ = try SiltaBinary.run(
        ["task", "add", "Acme release", "--start"], in: scratch,
        environment: TaskCommandTests.actor)
      let rival = ["SILTA_ACTOR": "agent:codex:other"]
      let stolen = try SiltaBinary.run(
        ["task", "start", "AC-1", "--steal", "--approved", "  Take this claim. \n", "--json"],
        in: scratch, environment: rival)
      #expect(stolen.termination == .exit(0))
      Golden.forTests().check(stolen.stdout, "task-start-approved.json")
      let done = try SiltaBinary.run(
        ["task", "done", "AC-1", "--force", "--allow-secret", "--approved", "Close it.",
         "-m", "Acme released.", "--json"], in: scratch, environment: rival)
      #expect(done.termination == .exit(0))
      try store.read { db in
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM approval ORDER BY id")
        #expect(rows.count == 2)
        #expect(rows.first?["words"] as String? == "Take this claim.")
        #expect(rows.first?["workspace"] as String? == "acme")
        #expect(rows.first?["actor"] as String? == "agent:codex:other")
        let command = rows.last?["command"] as String? ?? ""
        #expect(command.contains("--force") && command.contains("--allow-secret"))
        #expect(command.contains("AC-1") && !command.contains("Acme released."))
        #expect(!command.contains("Close it."))
      }
    }
  }

  @Test(arguments: ["", " \n\t", "<the human's words>", " <yes> ",
                    String(repeating: "a", count: 301), String(repeating: "e\u{301}", count: 151)])
  func invalidApprovalWordsRefuseBeforeFileIO(words: String) throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(
        ["ws", "edit", "-F", "absent.yaml", "--approved", words, "--json"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains("\"code\":\"invalid\""))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home").path))
    }
  }

  @Test func unusedApprovalIsIgnoredAndReadOnlyShowHasWrittenContract() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let unused = try SiltaBinary.run(
        ["--approved", "<placeholder>", "ws", "show", "--json"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(unused.termination == .exit(0))
      #expect(unused.stdout.contains("approval_unused"))
      let shown = try SiltaBinary.run(["ws", "show", "--json"], in: scratch)
      #expect(shown.termination == .exit(0))
      Golden.forTests().check(shown.stdout, "ws-show.json")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }

  @Test func workspaceFileEditIsApprovedAndSurvivesRestart() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let file = scratch.appending(path: "workspace.yaml")
      try "workspace: {slug: acme, name: Acme Updated, task_prefix: AC}\n".write(
        to: file, atomically: true, encoding: .utf8)
      let edited = try SiltaBinary.run(
        ["ws", "edit", "acme", "-F", file.path, "--approved", "Apply this YAML.", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(edited.termination == .exit(0))
      Golden.forTests().check(edited.stdout, "ws-edit-approved.json")
      let shown = try SiltaBinary.run(["ws", "show"], in: scratch)
      #expect(shown.termination == .exit(0))
      #expect(shown.stdout.contains("Acme Updated"))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
    }
  }

  @Test(arguments: ["--json", "--quiet", "--verbose", "--deterministic", "--help", "--ws", "--",
                    "task"])
  func approvalWordsStayOpaqueToRawScanners(words: String) throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      for args in [
        ["--approved", words, "ws", "show"],
        ["--approved=" + words, "ws", "show"],
        ["ws", "show", "--approved", words],
      ] {
        let result = try SiltaBinary.run(args, in: scratch)
        #expect(result.termination == .exit(0))
        #expect(result.stdout.hasPrefix("workspace:"))
        #expect(result.stderr.contains("approval_unused"))
      }
      let failed = try SiltaBinary.run(
        ["--approved", words, "task", "ls", "--nope"], in: scratch)
      #expect(failed.termination == .exit(1))
      #expect(failed.stderr.contains("next: silta task ls --help"))
    }
  }
}
