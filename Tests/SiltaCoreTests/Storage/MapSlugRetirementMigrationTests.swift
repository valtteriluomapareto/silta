import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct MapSlugRetirementMigrationTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["SILTA_SLOW_TESTS"] == "1"),
    .enabled(if: ProcessInfo.processInfo.environment["SILTA_V10_BINARY"] != nil)
  )
  func actualV10WriterRefusesMapSlugRetirementFloor() throws {
    let binary = try #require(ProcessInfo.processInfo.environment["SILTA_V10_BINARY"])
    try withScratchDirectory { scratch in
      let document = scratch.appending(path: "remove-api.yml")
      try AcmeDocAttachments.yaml(removing: "app").write(
        to: document, atomically: true, encoding: .utf8)
      for upgraded in [false, true] {
        let home = scratch.appending(path: upgraded ? "upgraded" : "original")
        let store = try fixture(home)
        if upgraded { try store.initialize() }
        let before = try snapshot(store)
        let shown = try old(binary, ["ws", "show"], home)
        #expect(shown.termination == .exit(0))
        let result = try old(
          binary, ["ws", "edit", "-F", document.path, "--approved", "Remove Acme API.", "--json"],
          home)
        let after = try snapshot(store)
        if upgraded {
          #expect(result.termination == .exit(9))
          #expect(result.stdout.contains("Database requires a newer version of silta."))
          #expect(after == before)
        } else {
          #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
          #expect(before.contains("app|api") && !after.contains("app|api"))
          #expect(after.contains(#"{"_retired_map_slugs":{"app":["historical"]}}"#))
        }
      }
    }
  }

  private func fixture(_ home: URL) throws -> DatabaseStore {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let store = StorageSchemaTests.store(home)
    let queue = try DatabaseQueue(path: store.path)
    try StorageSchema.migrator.migrate(queue, upTo: "v10")
    try queue.write {
      try $0.execute(
        sql: """
          INSERT INTO workspace(id,uid,slug,name,task_prefix)
            VALUES(1,'acme','acme','Acme','AC');
          INSERT INTO repo(id,uid,workspace_id,slug) VALUES(1,'repo',1,'platform');
          INSERT INTO app(id,uid,workspace_id,repo_id,slug,name,ref,is_primary)
            VALUES(1,'app',1,1,'api','api','main',1);
          UPDATE workspace SET settings='{"_retired_map_slugs":{"app":["historical"]}}';
          """)
    }
    return store
  }

  private func snapshot(_ store: DatabaseStore) throws -> [String] {
    let queue = try DatabaseQueue(path: store.path)
    return try queue.read {
      try String.fetchAll(
        $0,
        sql: """
          SELECT uid || '|' || slug FROM app
          UNION ALL SELECT key || '|' || value FROM meta
          UNION ALL SELECT settings FROM workspace
          UNION ALL SELECT command FROM approval
          ORDER BY 1
          """)
    }
  }

  private func old(_ binary: String, _ arguments: [String], _ home: URL) throws -> CLIResult {
    try SiltaBinary.runProcess(
      URL(filePath: binary), ["--ws", "acme"] + arguments, in: home,
      environment: ["SILTA_HOME": home.path, "SILTA_ACTOR": "agent:codex:acme"])
  }
}
