import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(2)))
struct DogfoodLogTests {
  static func setup(_ scratch: URL) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(scratch)
    try store.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO workspace(uid,slug,name,task_prefix)
          VALUES('beta','beta','Acme Beta','BE');
          INSERT INTO repo(uid,workspace_id,slug) VALUES('acme-repo',1,'platform');
          INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref)
          VALUES('acme-api',1,'api','Acme API',1,'main');
          INSERT INTO task(uid,workspace_id,seq,title,status,app_id,created_by,
            created_at,updated_at)
          VALUES('acme-task',1,1,'Acme','doing',1,'agent:codex:acme','','');
          """)
    }
    return store
  }

  static func run(_ args: [String], scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      args + ["--json", "--deterministic"], in: scratch,
      environment: TaskBlockCommandTests.environment)
  }

  static func last(_ scratch: URL) throws -> [String: Any] {
    let text = try String(
      contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
    let line = try #require(text.split(separator: "\n").last)
    return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
  }

  @Test func recordsResolvedSelectionAndNamedAppOnceWithoutBodies() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix)
            VALUES('acme-beta','beta','Acme Beta','BE');
            INSERT INTO repo(uid,workspace_id,slug) VALUES('acme-repo',1,'platform');
            INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref)
            VALUES('acme-app',1,'api','Acme API',1,'main');
            """)
      }
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(
          args + ["--deterministic", "--json"], in: scratch,
          environment: TaskBlockCommandTests.environment)
      }
      #expect(try run(["ws", "use", "beta"]).termination == .exit(0))
      #expect(try run(["ws", "show", "acme"]).termination == .exit(0))
      #expect(
        try run(["--ws", "acme", "task", "add", "Acme private title", "--app", "api"]).termination
          == .exit(0))
      #expect(try run(["--ws", "acme", "task", "show", "AC-1"]).termination == .exit(0))
      #expect(try run(["--ws", "acme", "task", "submit", "AC-1"]).termination == .exit(6))
      #expect(try run(["--ws", "acme", "task", "ls", "--app", "absent"]).termination == .exit(0))
      try store.write {
        try $0.database.execute(sql: "DELETE FROM meta WHERE key='current_workspace'")
      }
      #expect(try run(["--ws", "acme", "task", "show", "AC-1"]).termination == .exit(0))
      let text = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
      let entries = try text.split(separator: "\n").map {
        try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
      }
      #expect(entries.count == 7)
      #expect(
        entries.compactMap { $0["workspace"] as? String } == [
          "beta", "acme", "acme", "acme", "acme", "acme", "acme",
        ])
      #expect(entries[2]["app"] as? String == "api")
      #expect(entries.indices.filter { entries[$0]["app"] != nil } == [2])
      #expect(!text.contains("Acme private title"))
      #expect(
        Set(entries[2].keys) == [
          "timestamp", "command", "actor", "exit_code", "milliseconds", "flags", "warnings",
          "workspace", "app",
        ])
    }
  }

  @Test(arguments: [
    ["show", "AC-1"], ["start", "AC-1"], ["submit", "AC-1"],
    ["done", "AC-1", "--no-sha", "-m", "Acme"], ["drop", "AC-1", "-m", "Acme"],
    ["plan", "AC-1", "-m", "Acme plan"],
    ["edit", "AC-1", "-F", "missing", "--approved", "Edit Acme"],
    ["archive", "AC-1"], ["keep", "AC-1"], ["link", "AC-1", "url:https://example.com/acme"],
    ["promote", "AC-1", "--ext", "ado:42", "--approved", "Track Acme"],
    ["block", "AC-1", "-m", "Acme"], ["unblock", "AC-1"],
    ["triage", "--accept", "AC-1", "--approved", "Accept Acme"],
    ["from-plan", "--parent", "AC-1", "--dry-run"], ["ls", "--app", "api"],
    ["add", "Acme next", "--app", "api"],
  ])
  func everyTaskCommandLogsItsWorkspaceAndOnlyANamedApp(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let result = try Self.run(["--ws", "acme", "task"] + arguments, scratch: scratch)
      let entry = try Self.last(scratch)
      #expect(entry["workspace"] as? String == "acme")
      #expect(entry["app"] as? String == (arguments.contains("--app") ? "api" : nil))
      let code = try #require(entry["exit_code"] as? Int32)
      #expect(result.termination == .exit(code))
    }
  }

  @Test(arguments: [
    (["--ws", "beta", "ws", "show", "acme"], "acme"), (["ws", "show"], "acme"),
    (["ws", "use", "beta"], "beta"), (["--ws", "beta", "repo", "fetch"], "beta"),
    (["ws", "use", "absent"], nil),
  ])
  func workspaceCommandsLogTheWorkspaceTheyResolve(arguments: [String], workspace: String?)
    throws
  {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      _ = try Self.run(arguments, scratch: scratch)
      #expect(try Self.last(scratch)["workspace"] as? String == workspace)
    }
  }

  @Test func invalidIdentitiesNeverLeakAndKnownWorkspaceSurvivesMissingTask() throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let secret = "Pwd=" + "acme-secret"
      #expect(
        try Self.run(["--ws", secret, "task", "ls"], scratch: scratch).termination == .exit(2))
      #expect(try Self.last(scratch)["workspace"] == nil)
      #expect(
        try Self.run(["--ws", "acme", "task", "show", secret], scratch: scratch).termination
          == .exit(1))
      #expect(try Self.last(scratch)["workspace"] as? String == "acme")
      #expect(try Self.last(scratch)["app"] == nil)
      #expect(
        try Self.run(["--ws", "acme", "task", "ls", "--app", secret], scratch: scratch).termination
          == .exit(0))
      #expect(try Self.last(scratch)["app"] == nil)
      let log = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
      #expect(!log.contains("acme-secret"))
    }
  }

  @Test func namedAppCannotResolveFromAnotherWorkspace() throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let result = try Self.run(["--ws", "beta", "task", "ls", "--app", "api"], scratch: scratch)
      #expect(result.termination == .exit(0))
      let entry = try Self.last(scratch)
      #expect(entry["workspace"] as? String == "beta" && entry["app"] == nil)
    }
  }

  @Test func positionalWorkspaceEditAndNewScanOverrideCurrentSelection() throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let edit = try Self.run(
        ["--ws", "acme", "ws", "edit", "beta", "-F", "missing"], scratch: scratch)
      #expect(edit.termination == .exit(3))
      #expect(try Self.last(scratch)["workspace"] as? String == "beta")
      let repo = scratch.appending(path: "gamma-repo")
      try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
      _ = try DogfoodInstallTests.git(["init", "-q", "-b", "main"], in: scratch, cwd: repo)
      let scan = try Self.run(["init", "--scan", repo.path], scratch: scratch)
      #expect(scan.termination == .exit(0))
      let data = try #require(
        try JSONSerialization.jsonObject(with: Data(scan.stdout.utf8)) as? [String: Any])
      let workspace = try #require((data["data"] as? [String: Any])?["workspace"] as? String)
      #expect(workspace != "acme")
      #expect(try Self.last(scratch)["workspace"] as? String == workspace)
    }
  }

  @Test func firstWorkspaceEditLogsItsProducedIdentityWithoutCurrentSelection() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "workspace.yaml")
      try Data("workspace: {slug: beta, name: Acme Beta, task_prefix: BE}\n".utf8).write(to: file)
      let result = try Self.run(
        [
          "ws", "edit", "-F", file.path,
          "--approved", "Set up this Acme workspace",
        ], scratch: scratch)
      #expect(result.termination == .exit(0))
      let entry = try Self.last(scratch)
      #expect(entry["workspace"] as? String == "beta")
    }
  }

  @Test(arguments: [
    ["schema"], ["ws", "ls"], ["init", "--scan", "missing-acme"], ["init"], ["--version"],
    ["--help"], ["task"], ["task", "show", "--help"],
  ])
  func commandsThatActOnNoWorkspaceStayUntagged(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      _ = try Self.run(arguments, scratch: scratch)
      let entry = try Self.last(scratch)
      #expect(entry["command"] is String && entry["workspace"] == nil)
    }
  }

  @Test func absentStorageAttributionDoesNotInitializeDatabase() throws {
    try withScratchDirectory { scratch in
      let result = try Self.run(["task", "show", "AC-1"], scratch: scratch)
      #expect(result.termination == .exit(2))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
      let entry = try Self.last(scratch)
      #expect(entry["workspace"] == nil && entry["app"] == nil)
    }
  }

  @Test func realUsageFailuresReachTheWorkspaceReportWithoutOpaqueValues() throws {
    try withScratchDirectory { scratch in
      let store = try DogfoodReportTests.setup(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      let secret = "Pwd=" + "acme-secret"
      let cases: [[String]] = [
        ["--ws", "silta", "task", "show"],
        ["task", "show"],
        ["--ws=silta", "task", "show", "--approved", "--ws=acme"],
        ["--ws", "silta", "task", "show", "-m", "--ws=acme"],
        ["--ws", secret, "task", "show"],
        ["--ws", "silta", "task", "show", "--acme-unknown"],
      ]
      for (index, arguments) in cases.enumerated() {
        if index == 1 {
          try store.write {
            try $0.database.execute(
              sql: "UPDATE meta SET value='silta' WHERE key='current_workspace'")
          }
        }
        let result = try Self.run(arguments, scratch: scratch)
        #expect(result.termination == .exit(1))
        let entry = try Self.last(scratch)
        #expect(entry["error_code"] as? String == "usage")
        #expect(entry["workspace"] as? String == (index == 4 ? nil : "silta"))
      }
      let report = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(report.termination == .exit(0))
      #expect(report.stdout.contains("| silta task show | 5 | 100% | usage: 5 | 5 |"))
      #expect(!report.stdout.contains("acme-secret"))
    }
  }
}

extension DogfoodLogTests {
  /// One successful call per `silta schema` command, chained in one home whose current
  /// workspace is beta, with the workspace each log line must name.
  static func catalog(_ scratch: URL) throws -> [(args: [String], workspace: String?)] {
    let edit = scratch.appending(path: "edit.md")
    let sections = [
      ("Title", "Acme edited"), ("Description", "Acme description"),
      ("Acceptance", "Acme acceptance"), ("Plan", "- [ ] Acme step"), ("Result", ""),
    ]
    try Data(sections.map { "## \($0.0)\n~~~\n\($0.1)\n~~~\n" }.joined().utf8).write(to: edit)
    let plan = scratch.appending(path: "plan.md")
    try Data("# Acme plan\n\n- [ ] Acme step\n".utf8).write(to: plan)
    let yaml = scratch.appending(path: "beta.yaml")
    try Data("workspace: {slug: beta, name: Acme Beta Two, task_prefix: BE}\n".utf8).write(to: yaml)
    let acme = ["--ws", "acme"]
    return [
      (acme + ["task", "add", "Acme work", "--start"], "acme"),
      (acme + ["task", "show", "AC-1"], "acme"),
      (acme + ["comment", "AC-1", "-m", "Acme discussion"], "acme"),
      (acme + ["task", "edit", "AC-1", "-F", edit.path], "acme"),
      (acme + ["task", "plan", "AC-1", "-m", "- [ ] Acme step"], "acme"),
      (acme + ["task", "submit", "AC-1"], "acme"),
      (acme + ["task", "add", "Acme idea"], "acme"),
      (acme + ["task", "triage", "--accept", "AC-2", "--approved", "Accept Acme"], "acme"),
      (acme + ["task", "start", "AC-2"], "acme"),
      (acme + ["task", "block", "AC-2", "-m", "Acme waits"], "acme"),
      (acme + ["task", "unblock", "AC-2", "--approved", "Unblock Acme"], "acme"),
      (acme + ["task", "link", "AC-2", "url:https://example.com/acme"], "acme"),
      (acme + ["task", "done", "AC-2", "--no-sha", "-m", "Acme done"], "acme"),
      (acme + ["task", "archive", "AC-2"], "acme"),
      (acme + ["task", "keep", "AC-2"], "acme"),
      (acme + ["task", "add", "Acme other idea"], "acme"),
      (acme + ["task", "drop", "AC-3", "-m", "Acme no"], "acme"),
      (acme + ["task", "add", "Acme tracked idea"], "acme"),
      (acme + ["task", "triage", "--accept", "AC-4", "--approved", "Accept Acme"], "acme"),
      (acme + ["task", "promote", "AC-4", "--ext", "ado:42", "--approved", "Track Acme"], "acme"),
      (acme + ["task", "from-plan", plan.path, "--dry-run"], "acme"),
      (acme + ["task", "ls", "--app", "api"], "acme"),
      (acme + ["repo", "fetch"], "acme"),
      (acme + ["code", "show", "api", ".gitignore"], "acme"),
      (acme + ["code", "grep", "api", "build"], "acme"),
      (acme + ["code", "log", "api"], "acme"),
      (acme + ["code", "ls", "api"], "acme"),
      (["where", "--path", scratch.appending(path: "clone").path], "acme"),
      (["ws", "show", "acme"], "acme"),
      (["ws", "edit", "beta", "-F", yaml.path, "--approved", "Rename Acme Beta"], "beta"),
      (["ws", "ls"], nil),
      (["schema"], nil),
      (["doctor", "--ws", "absent"], nil),
      (["init"], nil),
      (["ws", "use", "acme"], "acme"),
    ]
  }

  @Test func everyCatalogCommandLogsTheWorkspaceItResolvedOnSuccess() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let clone = try DogfoodInstallTests.clone(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Acme Beta','BE');
            INSERT INTO repo(uid,workspace_id,slug) VALUES('acme-repo',1,'platform');
            INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref)
            VALUES('acme-api',1,'api','Acme API',1,'main');
            INSERT INTO repo_path(repo_id,path) VALUES(1,?);
            UPDATE meta SET value='beta' WHERE key='current_workspace';
            """, arguments: [clone.path])
      }
      let schema = try Self.run(["schema"], scratch: scratch)
      let object = try #require(
        try JSONSerialization.jsonObject(with: Data(schema.stdout.utf8)) as? [String: Any])
      let commands = try #require(
        (object["data"] as? [String: Any])?["commands"] as? [[String: Any]])
      let names = Set(commands.compactMap { $0["name"] as? String })
      var covered: Set<String> = []
      for (args, workspace) in try Self.catalog(scratch) {
        let result = try Self.run(args, scratch: scratch)
        #expect(result.termination == .exit(0), "\(args) \(result.stdout)")
        let entry = try Self.last(scratch)
        let command = try #require(entry["command"] as? String)
        covered.insert(command)
        #expect(entry["workspace"] as? String == workspace, "\(command)")
      }
      #expect(covered == names)
    }
  }

  @Test(arguments: [
    (["--ws", "acme", "task", "list"], "acme"), (["task", "frobnicate"], "acme"),
    (["--ws", "acme", "ws", "show", "beta", "extra"], nil),
    (["--ws", "acme", "ws", "use"], nil),
  ])
  func usageErrorsNameOnlyAWorkspaceTheyCouldResolve(arguments: [String], workspace: String?)
    throws
  {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      #expect(try Self.run(arguments, scratch: scratch).termination == .exit(1))
      let entry = try Self.last(scratch)
      #expect(entry["error_code"] as? String == "usage")
      #expect(entry["workspace"] as? String == workspace)
    }
  }
}
