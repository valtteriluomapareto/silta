import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(2)))
struct DogfoodScopeBoundaryTests {
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
  func everyTaskIdentityPathLogsItsResolvedApp(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let result = try Self.run(["--ws", "acme", "task"] + arguments, scratch: scratch)
      let entry = try Self.last(scratch)
      #expect(entry["workspace"] as? String == "acme" && entry["app"] as? String == "api")
      let code = try #require(entry["exit_code"] as? Int32)
      #expect(result.termination == .exit(code))
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

  @Test(arguments: [false, true]) func batchAppIsPresentOnlyForOneCommonApp(mixed: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      try store.write { tx in
        try tx.database.execute(sql: "UPDATE task SET status='blocked'")
        try tx.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,created_by,
            created_at,updated_at)
            VALUES('acme-second',1,2,'Acme second','blocked',?,'agent:codex:acme','','')
            """, arguments: [mixed ? nil : 1])
      }
      #expect(
        try Self.run(["--ws", "acme", "task", "unblock", "AC-1", "AC-2"], scratch: scratch)
          .termination == .exit(0))
      let app = try Self.last(scratch)["app"] as? String
      #expect(app == (mixed ? nil : "api"))
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
      _ = try DogfoodToolingTests.git(["init", "-q", "-b", "main"], in: scratch, cwd: repo)
      let scan = try Self.run(["init", "--scan", repo.path], scratch: scratch)
      #expect(scan.termination == .exit(0))
      let data = try #require(
        try JSONSerialization.jsonObject(with: Data(scan.stdout.utf8)) as? [String: Any])
      let workspace = try #require((data["data"] as? [String: Any])?["workspace"] as? String)
      #expect(workspace != "acme")
      #expect(try Self.last(scratch)["workspace"] as? String == workspace)
    }
  }
}
