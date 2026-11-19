import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct WorkspaceCommandTests {
  @Test func listsAndSelectsWorkspace() throws {
    try withScratchDirectory { scratch in
      let clock = FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000))
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"), clock: clock, jitter: { 0 })
      try store.write {
        try $0.database.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
      }
      for json in [false, true] {
        let suffix = json ? ["--json"] : []
        let listed = try SiltaBinary.run(["ws", "ls"] + suffix, in: scratch)
        #expect(listed.termination == .exit(0))
        if !json {
          withKnownIssue("#265: the workspace list does not label its text columns") {
            #expect(listed.stdout.hasPrefix("SLUG\tNAME\tTASK PREFIX\n"))
          }
        }
        Golden.forTests().check(listed.stdout, json ? "ws-ls.json" : "ws-ls.txt")
        let selected = try SiltaBinary.run(["ws", "use", "acme"] + suffix, in: scratch)
        #expect(selected.termination == .exit(0))
        Golden.forTests().check(selected.stdout, json ? "ws-use.json" : "ws-use.txt")
      }
      let quiet = try SiltaBinary.run(["ws", "ls", "--quiet"], in: scratch)
      #expect(quiet.termination == .exit(0))
      #expect(quiet.stdout == "acme\tAcme\tAC\n")
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='current_workspace'")
        } == "acme")
    }
  }

  @Test func workspaceNamesStayWithinTheirTerminalColumn() throws {
    try withScratchDirectory { scratch in
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"),
        clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
      let name = "Acme\u{1b}Projects\u{7}\u{2028}Work\tTeam"
      try store.write {
        try $0.database.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme',?,'AC')",
          arguments: [name])
      }
      for flags in [[], ["--quiet"]] {
        let shown = try SiltaBinary.run(["ws", "ls"] + flags, in: scratch)
        #expect(shown.termination == .exit(0))
        #expect(shown.stdout.contains("acme\tAcme Projects  Work Team\tAC\n"))
      }
      let result = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
      let data = try TaskStateRegressionTests.data(result)
      let workspaces = try #require(data["workspaces"] as? [[String: Any]])
      #expect(workspaces.first?["name"] as? String == name)
    }
  }

  @Test func unapprovedAgentCannotReadWorkspaceInput() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(
        ["ws", "edit", "-F", "missing.yaml"], in: scratch,
        environment: ["SILTA_ACTOR": "agent:codex:acme", "EDITOR": "/usr/bin/false"])
      #expect(result.termination == .exit(3))
      Golden.forTests().check(result.stderr, "ws-edit-refused.txt")
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
    }
  }
  @Test(arguments: [
    ["--ws", "acme", "ws", "use", "--nope"],
    ["ws", "--ws", "acme", "use", "--nope"],
  ])
  func workspaceOptionDoesNotHideErrorCommand(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(arguments, in: scratch)
      #expect(result.termination == .exit(1))
      #expect(result.stderr.contains("next: silta ws use --help"))
    }
  }

  @Test func emptyAndStaleSelectionAreRecoverable() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["ws", "ls"], in: scratch)
      #expect(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "ws-ls-empty.txt")
      let missing = try SiltaBinary.run(["ws", "use", "absent", "--json"], in: scratch)
      #expect(missing.termination == .exit(2))
      #expect(missing.stdout.contains("silta ws ls"))
    }
  }

  @Test(arguments: [["ws", "edit", "other"], ["--ws", "other", "ws", "edit"]])
  func refusalRetainsExplicitWorkspace(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      for json in [false, true] {
        let result = try SiltaBinary.run(
          arguments + ["-F", "missing.yaml"] + (json ? ["--json"] : []), in: scratch,
          environment: ["SILTA_ACTOR": "agent:codex:acme"])
        #expect(result.termination == .exit(3))
        Golden.forTests().check(
          json ? result.stdout : result.stderr,
          json ? "ws-edit-target-refused.json" : "ws-edit-target-refused.txt")
      }
    }
  }

  @Test func refusalQuotesWorkspaceShellCharacters() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(
        ["ws", "edit", "acme's", "-F", "missing.yaml", "--json"], in: scratch,
        environment: ["SILTA_ACTOR": "agent:codex:acme"])
      #expect(result.termination == .exit(3))
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let error = try #require(object["error"] as? [String: Any])
      #expect(
        error["next"] as? [String] == [
          "silta ws edit 'acme'\\''s' -F <file> --approved \"<the human's words>\""
        ])
    }
  }

}
