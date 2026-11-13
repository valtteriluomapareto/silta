import Foundation
import GRDB

/// Real document rows and complete database snapshots for command tests.
enum RestoreDocumentCommandFixture {
  static func seed(_ scratch: URL, workspace: String = "acme", slug: String = "rules") throws {
    try ExportCommandTests.seed(scratch)
    try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path).write { db in
      try db.execute(sql: "UPDATE workspace SET slug=?", arguments: [workspace])
      try db.execute(
        sql: """
          INSERT INTO service(id,uid,workspace_id,slug,name)
          VALUES(400,'delivery-service',1,'delivery','Delivery');
          INSERT INTO doc(id,uid,workspace_id,slug,title,kind,current_rev,created_at,updated_at)
          VALUES(100,'policy-doc',1,:slug,'Policy','contract',1,'','');
          INSERT INTO doc_rev(id,uid,doc_id,rev,body_md,state,actor,created_at,title,kind,
            about_refs,source_task_id)
          VALUES(200,'policy-rev',100,1,'Original rule.','accepted','human:acme','','Policy',
            'contract','["service:delivery"]',(SELECT id FROM task WHERE seq=1));
          INSERT INTO doc_verification(uid,doc_rev_id,actor,app_shas,created_at)
          VALUES('policy-verification',200,'human:acme','[]','');
          INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,created_at)
          VALUES('policy-comment',200,1,'comment','Keep this.','human:acme','');
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
            created_by,created_at)
          VALUES('policy-about',1,'doc',100,'about','service',400,'human:acme','');
          INSERT INTO seq_counter(scope,next)
          VALUES('doc_rev:1:'||:slug,2),('comment:doc_rev:200',2);
          """, arguments: ["slug": slug])
    }
  }

  static func dump(_ queue: DatabaseQueue) throws -> [String: [String]] {
    try queue.read { db in
      var result: [String: [String]] = [:]
      for table in try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
      {
        result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table)").map(\.description)
          .sorted()
      }
      return result
    }
  }
}
