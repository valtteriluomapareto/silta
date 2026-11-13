import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

struct TaskBlockMigrationTests {
  @Test func upgradesV2WithoutReplacingIdentityOrUnknownColumns() throws {
    try withScratchDirectory { home in
      let queue = try DatabaseQueue(path: home.appending(path: "silta.db").path)
      try StorageSchema.migrator.migrate(queue, upTo: "v2")
      try queue.write { db in
        try db.execute(
          sql: """
            ALTER TABLE task ADD COLUMN future TEXT DEFAULT 'default';
            INSERT INTO workspace(uid,slug,name,task_prefix,settings)
            VALUES('acme','acme','Acme','AC','{"future":42}');
            INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
            VALUES('acme-task',1,1,'Acme','todo','human:acme','','');
            UPDATE task SET future='Acme retained';
            """)
      }
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      try store.read { db in
        let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM task"))
        #expect(row["follow_up_at"] as String? == nil && row["future"] as String == "Acme retained")
        #expect(row["uid"] as String == "acme-task" && row["id"] as Int64 == 1)
        let version = try String.fetchOne(
          db, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
        let settings = try String.fetchOne(db, sql: "SELECT settings FROM workspace")
        #expect(version == "6" && settings == "{\"future\":42}")
      }
      let backups = try FileManager.default.contentsOfDirectory(
        atPath: home.appending(path: "backups").path)
      #expect(backups == ["silta-2023-11-14-before-v3-1700000000000.db"])
    }
  }
}
