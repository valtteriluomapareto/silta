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
        [
          "task", "done", "AC-1", "--force", "--allow-secret", "--approved", "Close it.",
          "-m", "Acme released.", "--json",
        ], in: scratch, environment: rival)
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

  @Test(arguments: [
    "", " \n\t", "<the human's words>", " <yes> ",
    String(repeating: "a", count: 301), String(repeating: "e\u{301}", count: 151),
  ])
  func invalidApprovalWordsRefuseBeforeFileIO(words: String) throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(
        ["ws", "edit", "-F", "absent.yaml", "--approved", words, "--json"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains("\"code\":\"invalid\""))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
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

  @Test(arguments: [
    "--json", "--quiet", "--verbose", "--deterministic", "--help", "--ws", "--",
    "task",
  ])
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
      let directory = scratch.appending(path: "silta-home/log")
      for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
        let log = try String(contentsOf: directory.appending(path: file), encoding: .utf8)
        for line in log.split(separator: "\n") {
          let entry = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
          #expect(entry["flags"] as? [String] == ["--approved"])
          #expect(["silta ws show", "silta task ls"].contains(entry["command"] as? String ?? ""))
        }
      }
    }
  }
}

extension ApprovalCommandTests {
  @Test func richAddRecoveryReplaysTheApprovedOperation() throws {
    try withScratchDirectory { scratch in
      let repo = try preparedApp(scratch)
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"), clock: SystemClock(), jitter: { 0 })
      let args = [
        "--ws", "acme", "task", "add", "Acme child", "--start", "--parent", "AC-1",
        "--app", "acme-platform-api", "--topic", "release", "--from", "note:acme",
        "--allow-secret", "-F", "absent.md", "--json",
      ]
      let refused = try SiltaBinary.run(
        args, in: scratch, cwd: repo,
        environment: TaskCommandTests.actor)
      #expect(refused.termination == .exit(3))
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(refused.stdout.utf8)) as? [String: Any])
      let error = try #require(object["error"] as? [String: Any])
      var retry = try #require((error["next"] as? [String])?.first)
      for flag in [
        "--start", "--parent 'AC-1'", "--app 'acme-platform-api'", "--topic 'release'",
        "--from 'note:acme'",
      ] {
        #expect(retry.contains(flag))
      }
      let file = scratch.appending(path: "body.md")
      try "Acme child body".write(to: file, atomically: true, encoding: .utf8)
      retry = shellWord(try SiltaBinary.url().path) + String(retry.dropFirst(5))
      retry = retry.replacingOccurrences(of: "'<title>'", with: "'Acme child'")
        .replacingOccurrences(of: "<file>", with: shellWord(file.path))
        .replacingOccurrences(of: "\"<the human's words>\"", with: "'Create this child.'")
      let replay = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", retry],
        in: scratch, cwd: repo, environment: TaskCommandTests.actor)
      #expect(replay.termination == .exit(0))
      try store.read { db in
        let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM task WHERE seq=2"))
        #expect(row["status"] as String == "doing")
        #expect(row["parent_id"] as Int64? == 1)
        #expect(row["app_id"] as Int64? != nil)
        #expect(row["description_md"] as String == "Acme child body")
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM link WHERE from_id=2") == 2)
        let command = try #require(try String.fetchOne(db, sql: "SELECT command FROM approval"))
        #expect(
          command.contains("--app 'acme-platform-api'") && command.contains("--parent 'AC-1'"))
        #expect(!command.contains("Acme child") && !command.contains(file.path))
      }
    }
  }

  private func preparedApp(_ scratch: URL) throws -> URL {
    let fixtures = scratch.appending(path: "acme")
    let made = try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"),
      [
        ScenarioRunner.repository.appending(path: "scripts/make-fixtures.sh").path, fixtures.path,
      ],
      in: scratch)
    #expect(made.termination == .exit(0))
    #expect(
      try SiltaBinary.run(["init", "--scan", fixtures.path], in: scratch).termination == .exit(0))
    #expect(try SiltaBinary.run(["ws", "use", "acme"], in: scratch).termination == .exit(0))
    let store = DatabaseStore(
      home: scratch.appending(path: "silta-home"), clock: SystemClock(), jitter: { 0 })
    try store.write {
      try $0.database.execute(
        sql:
          "INSERT INTO topic(uid,workspace_id,slug,name) VALUES('release',1,'release','Release')")
    }
    _ = try SiltaBinary.run(
      ["task", "add", "Acme root", "--start"], in: scratch,
      environment: TaskCommandTests.actor)
    return fixtures.appending(path: "acme-platform")
  }

  @Test func approvalWordsAreRedactedAndNeverLoggedWhileBodyOverrideIsRetained() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let secret = "Pwd=" + "acme-private"
      let result = try SiltaBinary.run(
        [
          "task", "add", "Acme", "--allow-secret", "--approved", "Yes " + secret,
          "-m", secret, "--json", "--verbose",
        ], in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("secret_redacted"))
      #expect(!result.stdout.contains(secret) && !result.stderr.contains(secret))
      try store.read { db in
        #expect(try String.fetchOne(db, sql: "SELECT description_md FROM task") == secret)
        let words = try #require(try String.fetchOne(db, sql: "SELECT words FROM approval"))
        #expect(words.contains("[REDACTED:") && !words.contains(secret))
      }
      let logs = scratch.appending(path: "silta-home/log")
      for file in try FileManager.default.contentsOfDirectory(atPath: logs.path) {
        let text = try String(contentsOf: logs.appending(path: file), encoding: .utf8)
        #expect(!text.contains("acme-private") && !text.contains("Yes "))
        #expect(text.contains("silta task add"))
      }
    }
  }
}

extension ApprovalCommandTests {
  @Test func workspaceInputErrorsKeepWorkspaceRecoveryAndNeverStoreRows() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let file = scratch.appending(path: "invalid.yaml")
      try Data([255]).write(to: file)
      for path in [file.path, file.path + "-absent"] {
        let result = try SiltaBinary.run(
          ["ws", "edit", "-F", path, "--approved", "Apply.", "--json"], in: scratch,
          environment: TaskCommandTests.actor)
        #expect(result.termination == .exit(9))
        #expect(result.stdout.contains("silta ws edit 'acme' -F <file>"))
        #expect(!result.stdout.contains("silta task add"))
      }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }

  @Test func workspaceFileInputAlsoReadsStdinWithoutHumanImpersonation() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let file = scratch.appending(path: "workspace.yaml")
      try "workspace: {slug: acme, name: Acme Piped, task_prefix: AC}".write(
        to: file, atomically: true, encoding: .utf8)
      let command =
        "cat " + shellWord(file.path) + " | " + shellWord(try SiltaBinary.url().path)
        + " ws edit -F - --approved 'Apply this.' --json"
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", command],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(0))
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT name FROM workspace") }
          == "Acme Piped")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT actor FROM approval") }
          == "agent:codex:acme")
    }
  }
}

extension ApprovalCommandTests {
  @Test func everySecretFlagPassesApprovedAgentWordsThroughTheCLI() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let plan = scratch.appending(path: "plan.md")
      try "# Acme import\n- One\n- Two".write(to: plan, atomically: true, encoding: .utf8)
      let secret = "Pwd=" + "acme-body"
      for args in [
        ["task", "add", "Acme", "--start", "--allow-secret", "-m", secret],
        ["task", "submit", "AC-1", "--allow-secret", "-m", secret],
        ["task", "plan", "AC-1", "--if-rev", "0", "--allow-secret", "-m", "- [ ] " + secret],
        ["task", "plan", "AC-1", "--if-rev", "1", "--step", "1", "--done", "--allow-secret"],
        ["task", "done", "AC-1", "--force", "--allow-secret", "--no-sha", "-m", secret],
        ["task", "from-plan", plan.path, "--split", "--allow-secret"],
        ["task", "drop", "AC-2", "--allow-secret", "-m", secret],
      ] {
        let result = try SiltaBinary.run(
          args + ["--approved", "Proceed.", "--json"],
          in: scratch, environment: TaskCommandTests.actor)
        #expect(result.termination == .exit(0), "\(args.prefix(2)): \(result.stdout)")
      }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 7)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT result_md FROM task WHERE seq=1") }
          == secret)
      let preview = try SiltaBinary.run(
        [
          "task", "from-plan", plan.path, "--dry-run", "--allow-secret", "--approved", "Preview.",
          "--json",
        ],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(preview.termination == .exit(0))
      #expect(!preview.stdout.contains("approval_unused"))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 7)
    }
  }

  @Test func approvedPlanRetryKeepsCASAndDoneRetryKeepsCommitOptions() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      _ = try SiltaBinary.run(
        ["task", "add", "Acme", "--start"], in: scratch,
        environment: TaskCommandTests.actor)
      _ = try SiltaBinary.run(
        ["task", "plan", "AC-1", "-m", "Original"], in: scratch,
        environment: TaskCommandTests.actor)
      let refused = try SiltaBinary.run(
        [
          "--ws", "acme", "task", "plan", "AC-1", "--if-rev", "1", "--allow-secret", "-F", "absent",
          "--json",
        ],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(refused.termination == .exit(3))
      #expect(refused.stdout.contains("--if-rev 1") && refused.stdout.contains("--approved"))
      _ = try SiltaBinary.run(
        ["task", "plan", "AC-1", "-m", "Advanced"], in: scratch,
        environment: TaskCommandTests.actor)
      let stale = try SiltaBinary.run(
        [
          "--ws", "acme", "task", "plan", "AC-1", "--if-rev", "1", "--allow-secret", "-m", "Retry",
          "--approved", "Replace it.", "--json",
        ],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(stale.termination == .exit(6) && stale.stdout.contains("stale_rev"))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
      let done = try SiltaBinary.run(
        ["task", "done", "AC-1", "--force", "--allow-secret", "--sha", "acme-commit", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(done.termination == .exit(3))
      #expect(done.stdout.contains("--force --sha 'acme-commit' --allow-secret -F <file>"))
      let noSHA = try SiltaBinary.run(
        ["task", "done", "AC-1", "--force", "--no-sha", "--json"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(noSHA.termination == .exit(3) && noSHA.stdout.contains("--force --no-sha -F <file>"))
    }
  }
}

extension ApprovalCommandTests {
  @Test func approvedFileEditBootstrapsAndUnusedQuoteDoesNotAuthorizeCreation() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "workspace.yaml")
      try "workspace: {slug: acme, name: Acme, task_prefix: AC}".write(
        to: file, atomically: true, encoding: .utf8)
      let edited = try SiltaBinary.run(
        ["ws", "edit", "-F", file.path, "--approved", "Create this workspace.", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(edited.termination == .exit(0))
      let added = try SiltaBinary.run(
        ["--ws", "acme", "task", "add", "Acme idea", "--approved", "<unused>", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(added.termination == .exit(0))
      #expect(added.stdout.contains("proposed") && added.stdout.contains("approval_unused"))
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"), clock: SystemClock(), jitter: { 0 })
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT workspace FROM approval") } == "acme")
    }
  }
}
