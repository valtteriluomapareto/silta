import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct TaskLinkMigrationTests {
  @Test func upgradesV1WithoutReplacingRowsOrUnknownFields() throws {
    try withScratchDirectory { scratch in
      let queue = try DatabaseQueue(path: scratch.appending(path: "silta.db").path)
      try StorageSchema.migrator.migrate(queue, upTo: "v1")
      try queue.write { db in
        try db.execute(
          sql: """
            ALTER TABLE task ADD COLUMN future TEXT DEFAULT 'Acme future';
            INSERT INTO workspace(uid,slug,name,task_prefix,settings)
            VALUES('acme','acme','Acme','AC','{"future":42}');
            INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
            VALUES('acme-task',1,1,'Acme','todo','human:acme','','');
            UPDATE task SET future='Acme retained';
            INSERT INTO link(
            uid,workspace_id,from_kind,from_id,rel,to_kind,to_ext,created_by,created_at)
            VALUES('acme-link',1,'task',1,'cites','url','https://example.com','human:acme','');
            """)
      }
      let store = StorageSchemaTests.store(scratch)
      try store.initialize()
      try store.read { db in
        let task = try #require(try Row.fetchOne(db, sql: "SELECT * FROM task"))
        let link = try #require(try Row.fetchOne(db, sql: "SELECT * FROM link"))
        #expect(task["future"] as String == "Acme retained")
        #expect(task["uid"] as String == "acme-task")
        #expect(link["uid"] as String == "acme-link")
        #expect(link["anchor"] as String? == nil)
        let settings = try String.fetchOne(db, sql: "SELECT settings FROM workspace")
        let version = try Int.fetchOne(
          db, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
        #expect(settings == "{\"future\":42}")
        #expect(version == 3)
      }
      let backups = try FileManager.default.contentsOfDirectory(
        atPath: scratch.appending(path: "backups").path)
      #expect(backups == ["silta-2023-11-14-before-v2-1700000000000.db"])
    }
  }
}
