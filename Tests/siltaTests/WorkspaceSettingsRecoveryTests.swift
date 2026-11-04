import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceSettingsRecoveryTests {
  @Test(
    arguments: ["{\"archive_after_days\":1.5}", "not-json", "null", "[]", "1.5"], [false, true])
  func badSettingsOfferUsableWorkspaceInspection(settings: String, json: Bool) throws {
    withKnownIssue("#13: stored settings and policy validation") {
      try withScratchDirectory { scratch in
        let store = DatabaseStore(
          home: scratch.appending(path: "silta-home"),
          clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
        try store.write {
          try $0.database.execute(
            sql: """
              INSERT INTO workspace(uid,slug,name,task_prefix,settings) VALUES('acme','acme','Acme','AC',?);
              INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at,closed_at)
              VALUES('acme-task',1,1,'Acme work','done','agent:codex:acme',
                '2023-11-14T22:13:20.000Z','2023-11-14T22:13:20.000Z','2023-11-14T22:13:20.000Z');
              """, arguments: [settings])
        }
        for command in [["task", "show", "AC-1"], ["task", "ls"]] {
          let result = try SiltaBinary.run(
            ["--ws", "acme"] + command + (json ? ["--json"] : []), in: scratch)
          #expect(result.termination == .exit(1))
          let output = json ? result.stdout : result.stderr
          #expect(output.contains(json ? "\"code\":\"invalid\"" : "[invalid]"))
          #expect(output.contains("archive_after_days"))
          #expect(output.contains("silta --ws 'acme' ws show"))
          #expect(!output.contains("doctor"))
          if settings.hasPrefix("{") && command[1] == "show" {
            Golden.forTests().check(output, "ws-stored-setting.\(json ? "json" : "txt")")
          }
        }
        let shown = try SiltaBinary.run(["--ws", "acme", "ws", "show"], in: scratch)
        #expect(shown.termination == .exit(0))
        #expect(shown.stdout.contains("settings:"))
        #expect(!shown.stdout.contains("settings: {}"))
        #expect(
          try store.read { try String.fetchOne($0, sql: "SELECT settings FROM workspace") }
            == settings)
      }
    }
  }
}
