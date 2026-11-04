import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceSettingsCommandTests {
  @Test(arguments: ["boolean", "typo"], [false, true])
  func invalidSettingsPreserveWorkspaceAndOfferRepair(kind: String, json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"),
        clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
      try store.write {
        try $0.database.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
      }
      let file = scratch.appending(path: "workspace.yaml")
      try
        ("workspace: {slug: acme, name: Acme, task_prefix: AC}\n"
        + "settings: {review_gate: \(kind == "boolean" ? "on" : "humna")}\n")
        .write(to: file, atomically: true, encoding: .utf8)
      let result = try SiltaBinary.run(
        [
          "--ws", "acme", "ws", "edit", "-F", file.path,
          "--approved", "Apply the Acme configuration",
        ] + (json ? ["--json"] : []),
        in: scratch, environment: ["SILTA_ACTOR": "agent:codex:acme"])
      #expect(result.termination == .exit(1))
      #expect((json ? result.stderr : result.stdout).isEmpty)
      Golden.forTests().check(
        json ? result.stdout : result.stderr,
        "ws-settings-\(kind).\(json ? "json" : "txt")")
      try store.read { (db: Database) throws in
        #expect(try String.fetchOne(db, sql: "SELECT settings FROM workspace") == "{}")
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 0)
      }
    }
  }
}
