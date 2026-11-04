import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport

extension BriefCommandTests {
  func normalizeBrief(_ text: String, _ repo: URL) -> String {
    text.replacingOccurrences(of: repo.path, with: "<repo>")
      .replacingOccurrences(of: repo.path.lowercased(), with: "<repo>")
  }

  func hookTimeoutCount(_ scratch: URL) throws -> Int {
    let directory = scratch.appending(path: "silta-home/log")
    guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    return try files.filter { $0.pathExtension == "jsonl" }.reduce(0) { count, file in
      count
        + (try String(contentsOf: file, encoding: .utf8)).split(separator: "\n")
        .filter { $0.contains("\"hook_timeout\"") }.count
    }
  }

  func seedTasks(_ store: DatabaseStore) throws {
    try store.write { tx in
      for (seq, app, actor, branch, status) in [
        (1, "api", "agent:codex:other", "api", "doing"),
        (2, "portal", "agent:codex:acme", "elsewhere", "doing"),
        (3, "api", "agent:codex:acme", "elsewhere", "doing"),
        (4, "api", "agent:codex:acme", "api", "done"),
      ] {
        try tx.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,claimed_by,claimed_at,
              branch,created_by,created_at,updated_at,plan_md)
            SELECT ?,workspace_id,?,'Acme task',?,id,?,'2023-11-14T22:13:20.000Z',?,
              'human:acme','2023-11-14T22:13:20.000Z','2023-11-14T22:13:20.000Z',
              '- [x] Acme ready
            - [ ] Acme next'
            FROM app WHERE slug=?
            """, arguments: ["acme-\(seq)", seq, status, actor, branch, app])
      }
    }
  }

  func run(_ flags: [String], _ repo: URL, _ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      ["brief", "--ws", "acme"] + flags, in: scratch, cwd: repo,
      environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
  }

  func store(_ scratch: URL) -> DatabaseStore {
    DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
  }

  func settings(_ json: String, _ scratch: URL) throws {
    try store(scratch).write {
      try $0.database.execute(sql: "UPDATE workspace SET settings=?", arguments: [json])
    }
  }
}
