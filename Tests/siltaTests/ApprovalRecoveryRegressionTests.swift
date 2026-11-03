import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ApprovalRecoveryRegressionTests {
  @Test(arguments: [
    (["ws", "edit", "-F", "absent.yaml"], "silta ws edit"),
    (["--ws", "acme", "task", "add", "Acme", "--allow-secret"], "silta --ws 'acme' task add"),
    (["task", "add", "Acme", "--allow-secret", "-F", "absent.md"], "silta task add"),
    (["task", "done", "AC-1", "--force", "-F", "absent.md"], "silta task done"),
    (["task", "plan", "AC-1", "--step", "1", "--done", "--allow-secret"], "silta task plan"),
    (["task", "from-plan", "absent.md", "--allow-secret"], "silta task from-plan"),
  ])
  func invalidApprovalOffersRunnableHelp(row: ([String], String)) throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(
        row.0 + ["--approved", "<placeholder>", "--json"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(1))
      if row.1 == "silta ws edit" {
        Golden.forTests().check(result.stdout, "ws-edit-invalid-approval.json")
        let text = try SiltaBinary.run(
          row.0 + ["--approved", "<placeholder>"],
          in: scratch, environment: TaskCommandTests.actor)
        Golden.forTests().check(text.stderr, "ws-edit-invalid-approval.txt")
      }
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let error = try #require(object["error"] as? [String: Any])
      let next = try #require((error["next"] as? [String])?.first)
      #expect(next == row.1 + " --help")
      #expect(error["next_by"] as? String == "agent")
      let actual = shellWord(try SiltaBinary.url().path) + String(next.dropFirst(5))
      let help = try SiltaBinary.runProcess(URL(filePath: "/bin/sh"), ["-c", actual], in: scratch)
      #expect(help.termination == .exit(0))
      #expect(help.stdout.hasPrefix("OVERVIEW:"))
    }
  }
}

extension ApprovalRecoveryRegressionTests {
  @Test func workspaceFailuresRetainNoncurrentTargetAndFileRepair() throws {
    try withScratchDirectory { scratch in
      let store = try workspaces(scratch)
      let file = scratch.appending(path: "input.yaml")
      let repair = "silta ws edit 'acme' -F <file> --approved \"<the human's words>\""
      let rename = Data("workspace: {slug: other, name: Acme, task_prefix: ZZ}".utf8)
      for (content, code) in [
        (Data("workspace: [".utf8), Int32(1)),
        (rename, Int32(1)),
        (Data("workspace: {slug: acme, name: Changed, task_prefix: AC}".utf8), Int32(6)),
        (Data([255]), Int32(9)),
        (nil, Int32(9)),
      ] {
        if let content { try content.write(to: file) }
        for prefix in [["ws", "edit", "acme"], ["--ws", "acme", "ws", "edit"]] {
          for json in [false, true] {
            let result = try SiltaBinary.run(
              prefix + ["-F", content == nil ? "absent.yaml" : file.path, "--approved", "Apply."]
                + (json ? ["--json"] : []), in: scratch, environment: TaskCommandTests.actor)
            #expect(result.termination == .exit(code))
            if content == rename {
              Golden.forTests().check(
                json ? result.stdout : result.stderr,
                json ? "ws-edit-rename-refused.json" : "ws-edit-rename-refused.txt")
            }
            if json {
              let object = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
              let error = try #require(object["error"] as? [String: Any])
              #expect(
                error["next"] as? [String]
                  == (code == 9 ? [repair] : ["silta ws show 'acme'", repair]))
            } else {
              #expect(result.stderr.contains(repair))
              if code != 9 { #expect(result.stderr.contains("silta ws show 'acme'")) }
            }
          }
        }
      }
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT name FROM workspace WHERE slug='acme'")
        } == "Acme")
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='current_workspace'")
        } == "beta")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }

  private func workspaces(_ scratch: URL) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(scratch)
    let columns = "uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at"
    try store.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
          UPDATE meta SET value='beta' WHERE key='current_workspace';
          INSERT INTO topic(uid,workspace_id,slug,name) VALUES('release',1,'release','Release');
          INSERT INTO link(\(columns))
          VALUES('link',1,'task',99,'about','topic',1,'agent:codex:acme','x');
          """)
    }
    return store
  }

  @Test func invalidQuoteNeverAppearsInDiagnosticsOrLogs() throws {
    try withScratchDirectory { scratch in
      let words = "<Acme-private-words>"
      let result = try SiltaBinary.run(
        ["ws", "edit", "-F", "absent.yaml", "--approved", words, "--json", "--verbose"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(1))
      #expect(!result.stdout.contains(words) && !result.stderr.contains(words))
      let log = scratch.appending(path: "silta-home/log")
      for file in try FileManager.default.contentsOfDirectory(atPath: log.path) {
        let text = try String(contentsOf: log.appending(path: file), encoding: .utf8)
        #expect(!text.contains(words))
      }
    }
  }
}

extension ApprovalRecoveryRegressionTests {
  @Test func missingWorkspaceKeepsListingRecoveryAndNoApprovalRow() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let file = scratch.appending(path: "workspace.yaml")
      try "workspace: {slug: acme, name: Acme, task_prefix: AC}".write(
        to: file, atomically: true, encoding: .utf8)
      let result = try SiltaBinary.run(
        ["ws", "edit", "absent", "-F", file.path, "--approved", "Apply.", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(2))
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let error = try #require(object["error"] as? [String: Any])
      #expect(error["next"] as? [String] == ["silta ws ls"])
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }
}
