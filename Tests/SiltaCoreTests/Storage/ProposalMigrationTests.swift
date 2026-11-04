import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct ProposalMigrationTests {
  @Test func raisesOnlyTheWriterFloor() throws {
    try withScratchDirectory { home in
      let queue = try DatabaseQueue(path: home.appending(path: "silta.db").path)
      try StorageSchema.migrator.migrate(queue, upTo: "v3")
      try queue.write {
        try $0.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix,settings)
            VALUES('acme','acme','Acme','AC','{"future":42}');
            """)
      }
      let schema = try queue.read {
        try String.fetchAll(
          $0, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name")
      }
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      try store.read { (db: Database) throws in
        #expect(
          try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'") == 4)
        #expect(try String.fetchOne(db, sql: "SELECT settings FROM workspace") == "{\"future\":42}")
        #expect(
          try String.fetchAll(
            db, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name") == schema)
      }
      #expect(DatabaseStore.writerVersion == 4)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: home.appending(path: "backups").path)
          == ["silta-2023-11-14-before-v4-1700000000000.db"])
    }
  }
}
