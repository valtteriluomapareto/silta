import Foundation
import GRDB

@testable import SiltaCore

/// Synthetic truth with replaceable physical IDs and deliberately literal history.
enum ExportDocumentSnapshotFixture {
  static func make(_ home: URL, offset o: Int64 = 0) throws -> DatabaseStore {
    let store = ExportFixture.store(home)
    try store.initialize()
    try store.write { try insert($0.database, offset: o) }
    return store
  }

  static func insert(_ db: Database, offset o: Int64) throws {
    let uid = ExportDocumentTests.uid
    try run(
      db,
      """
      INSERT INTO workspace(id,uid,slug,name,task_prefix) VALUES
      (?,'acme','acme','Acme','AC'),(?,'other','other','Other','OT');
      """, [17 + o, 23 + o])
    try run(
      db,
      """
      INSERT INTO task(id,uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
      VALUES(?,?,?,1,'Source task','todo','human:acme','','');
      """, [700 + o, uid("010"), 17 + o])
    try document(db, offset: o)
    try discussion(db, offset: o)
    try otherAndCounters(db, offset: o)
  }

  private static func run(
    _ db: Database, _ sql: String, _ values: [(any DatabaseValueConvertible)?] = []
  ) throws {
    try db.execute(sql: sql, arguments: StatementArguments(values))
  }

  private static func document(_ db: Database, offset o: Int64) throws {
    let uid = ExportDocumentTests.uid
    try run(
      db,
      """
      INSERT INTO doc(id,uid,workspace_id,slug,previous_slugs,title,kind,owner,current_rev,
        verified_at,archived,created_at,updated_at)
      VALUES(?,?,?,'push-rules','["old-rules"]','Push fallback','contract','human:acme',2,
        '2023-11-14T22:13:20.000Z',1,'2023-11-14T22:13:00.000Z','2023-11-14T22:13:20.000Z');
      """, [91 + o, uid("001"), 17 + o])
    try run(
      db,
      """
      INSERT INTO doc_rev(id,uid,doc_id,rev,body_md,state,actor,created_at)
      VALUES(?,?,?,1,?,'accepted','human:acme','2023-11-14T22:13:00.000Z');
      """, [902 + o, uid("002"), 91 + o, ExportDocumentTests.bodies[0]])
    try run(
      db,
      """
      INSERT INTO doc_rev(id,uid,doc_id,rev,base_rev,body_md,state,actor,message,created_at,
        title,kind,about_refs,source_task_id,triaged_at,triaged_by)
      VALUES(?,?,?,2,1,?,'accepted','agent:codex:acme','Clarify fallback',
        '2023-11-14T22:13:15.000Z','Push fallback','contract',?,?,
        '2023-11-14T22:13:20.000Z','human:acme');
      """,
      [
        901 + o, uid("003"), 91 + o, ExportDocumentTests.bodies[1],
        ExportDocumentTests.about, 700 + o,
      ])
    for (number, state) in [(3, "proposed"), (5, "rejected"), (7, "superseded")] {
      try run(
        db,
        """
        INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
        VALUES(?,?,?,?,?,'agent:codex:peer','2023-11-14T22:13:25.000Z');
        """, [uid("05\(number)"), 91 + o, number, "\(state) history", state])
    }
    try run(
      db,
      """
      INSERT INTO doc_verification(uid,doc_rev_id,actor,message,app_shas,created_at)
      VALUES(?,?,'human:acme','',?,'2023-11-14T22:13:20.000Z');
      """, [uid("030"), 901 + o, ExportDocumentTests.shas])
  }

  private static func discussion(_ db: Database, offset o: Int64) throws {
    let uid = ExportDocumentTests.uid
    try run(
      db,
      """
      INSERT INTO comment(id,uid,doc_rev_id,seq,kind,verdict,subject,anchor,anchor_sha,
        anchor_snippet,body_md,mentions,accepted,actor,resolved_at,resolved_by,created_at)
      VALUES(?,?,?,1,'review','changes','doc@2','#L1-2',?,'Keep the old rule.',
        'Check the fallback.','["human:acme"]',0,'agent:codex:peer',
        '2023-11-14T22:13:30.000Z','human:acme','2023-11-14T22:13:21.000Z');
      """, [44 + o, uid("040"), 901 + o, String(repeating: "a", count: 40)])
    try run(
      db,
      """
      INSERT INTO comment(uid,doc_rev_id,seq,thread_id,kind,body_md,mentions,accepted,actor,
        created_at) VALUES(?,?,2,?,'answer','Use the code rule.','[]',1,'human:acme',
        '2023-11-14T22:13:22.000Z');
      """, [uid("041"), 901 + o, 44 + o])
    try run(
      db,
      """
      INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,deleted_at,created_at)
      VALUES(?,?,7,'comment','','human:acme','2023-11-14T22:13:31.000Z',
        '2023-11-14T22:13:23.000Z');
      """, [uid("042"), 901 + o])
  }

  private static func otherAndCounters(_ db: Database, offset o: Int64) throws {
    try run(
      db,
      """
      INSERT INTO doc(id,uid,workspace_id,slug,title,kind,created_at,updated_at)
      VALUES(?,'other-doc',?,'push-rules','Other','contract','','');
      INSERT INTO doc_rev(id,uid,doc_id,rev,body_md,state,actor,created_at)
      VALUES(?,'other-revision',?,50,'Private','proposed','human:other','');
      """, [92 + o, 23 + o, 950 + o, 92 + o])
    try run(
      db,
      """
      INSERT INTO seq_counter(scope,next) VALUES(?,20),(?,71),(?,99),(?,9),(?,80),(?,44);
      """,
      [
        "doc_rev:\(17 + o):push-rules", "doc_rev:\(17 + o):gone-rules",
        "doc_rev:\(23 + o):gone-rules", "comment:doc_rev:\(901 + o)",
        "comment:doc_rev:\(950 + o)", "comment:doc_rev:4040404",
      ])
  }
}
