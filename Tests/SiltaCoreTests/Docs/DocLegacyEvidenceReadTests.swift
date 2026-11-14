import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocLegacyEvidenceReadTests {
  @Test(arguments: ["v1", "v2", "v3", "v4"])
  func historicalSchemasReadWhyAndDiffWithoutMigration(version: String) throws {
    try withScratchDirectory { scratch in
      let (store, queue) = try fixture(scratch, version: version)
      let before = try DocVerificationPreparationTests.truth(store)
      let columns = try queue.read { try $0.columns(in: "doc_rev").map(\.name) }
      #expect(!columns.contains("source_task_id") && !columns.contains("title"))
      for flags in [[], ["--diff"]] {
        for json in [false, true] {
          let result = try SiltaBinary.run(
            ["--ws", "acme", "doc", "show", "doc:rules@2"] + flags
              + (json ? ["--json"] : []), in: scratch)
          #expect(result.termination == .exit(0))
          #expect(result.stdout.contains("Legacy why"))
          if flags.isEmpty {
            #expect(result.stdout.contains("title: (unknown)"))
            #expect(result.stdout.contains("source_task: (not recorded)"))
            #expect(result.stdout.contains("triaged_by: (not recorded)"))
          } else {
            #expect(result.stdout.contains("diff against doc:rules@1"))
          }
          #expect(!result.stdout.contains("Projection title"))
        }
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      let migrations = try queue.read {
        try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
      }
      #expect(migrations.last == version && !migrations.contains("v5"))
    }
  }
  private func fixture(_ scratch: URL, version: String) throws -> (DatabaseStore, DatabaseQueue) {
    let home = scratch.appending(path: "silta-home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let store = DatabaseStore(
      home: home, clock: FakeClock(now: AcmeDocAttachments.instant), jitter: { 0 })
    let queue = try DatabaseQueue(path: store.path)
    try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=WAL") }
    try StorageSchema.migrator.migrate(queue, upTo: version)
    try queue.write {
      try $0.execute(
        sql: """
          INSERT INTO workspace(id,uid,slug,name,task_prefix)
          VALUES(1,'acme','acme','Acme','AC');
          INSERT INTO doc(id,uid,workspace_id,slug,title,kind,current_rev,created_at,updated_at)
          VALUES(1,'rules',1,'rules','Projection title','reference',1,'2023-11-14','2023-11-14');
          INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
          VALUES('base',1,1,'Base body','accepted','human:acme','2023-11-14');
          INSERT INTO doc_rev(uid,doc_id,rev,base_rev,body_md,state,actor,created_at,message)
          VALUES('next',1,2,1,'Next body','proposed',
            'agent:codex:writer','2023-11-15','Legacy why');
          """)
    }
    return (store, queue)
  }

}
