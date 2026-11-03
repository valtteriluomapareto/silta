import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DogfoodLogTests {
  @Test func recordsResolvedSelectionAndTaskAppOnceWithoutBodies() throws {
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
      #expect(entries[3]["app"] as? String == "api")
      #expect(entries[4]["app"] as? String == "api")
      #expect(entries[5]["app"] == nil && entries[0]["app"] == nil)
      #expect(!text.contains("Acme private title"))
      #expect(
        Set(entries[3].keys) == [
          "timestamp", "command", "actor", "exit_code", "milliseconds", "flags", "warnings",
          "workspace", "app",
        ])
    }
  }
}
