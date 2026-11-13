import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

/// A synthetic current-format graph retaining genuine legacy map identities.
enum RestoreDocumentGraphFixture {
  static func links() throws -> [ExportRow] {
    let files = try ExportTreeTests.golden("typed-doc-links")
    return try ExportFileReader(files: files, slug: "acme").jsonl(
      "links.jsonl", keys: ExportFormat.linkKeys)
  }

  static func graph() throws -> (tree: ExportSnapshot, documents: ExportDocumentSnapshot) {
    let legacy = try ExportTree.parse(ExportVersionTests.frozen())
    let source = ExportTask(
      ref: "AC-2",
      row: ExportDocumentTests.row([
        ("ref", "AC-2"), ("uid", ExportDocumentTests.uid("010")), ("seq", "2"),
        ("title", "Source task"), ("type", "feature"), ("status", "todo"), ("priority", "2"),
        ("description_md", ""), ("plan_md", ""), ("plan_rev", "0"), ("acceptance_md", ""),
        ("created_by", "human:acme"), ("created_at", "2023-11-14T22:13:00.000Z"),
        ("updated_at", "2023-11-14T22:13:00.000Z"),
      ]), records: [])
    let documents = try ExportDocumentSnapshot.parse(
      ExportDocumentSnapshotTests.golden(), workspace: "acme")
    let tree = ExportSnapshot(
      schema: "v7",
      workspace: legacy.workspace.replacing(
        "next_task_seq", with: "3", keys: ExportFormat.workspaceKeys),
      sections: legacy.sections, tasks: legacy.tasks + [source], documents: documents,
      links: try links(),
      aliasDecisions: legacy.aliasDecisions, approvals: legacy.approvals)
    return (tree, documents)
  }

  static func source(_ home: URL) throws -> DatabaseStore {
    let store = try ExportDocumentSnapshotFixture.make(home)
    try store.write { tx in
      try maps(tx.database)
      try tx.database.execute(
        sql: """
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,to_ext,
            created_by,created_at,anchor) VALUES
          ('typed-001',17,'task',700,'cites','doc',91,NULL,'human:acme',:at,NULL),
          ('typed-002',17,'task',700,'cites','doc_rev',901,NULL,'human:acme',:at,NULL),
          ('typed-003',17,'task',700,'cites','comment',45,NULL,'human:acme',:at,'#L1'),
          ('typed-004',17,'doc',91,'about','app',1102,NULL,'human:acme',:at,NULL),
          ('typed-005',17,'doc',91,'about','edge',1201,NULL,'human:acme',:at,NULL),
          ('typed-006',17,'doc',91,'about','service',1301,NULL,'human:acme',:at,NULL),
          ('typed-007',17,'doc',91,'about','topic',1401,NULL,'human:acme',:at,NULL),
          ('typed-008',17,'comment',44,'cites','service',1301,NULL,'human:acme',:at,NULL),
          ('typed-009',17,'doc',91,'cites','code',NULL,'doc:Sources/Rules.swift',
            'human:acme',:at,NULL),
          ('typed-010',17,'doc',91,'cites','code',NULL,'service@release:Sources/Push.swift',
            'human:acme',:at,NULL),
          ('private',23,'doc',92,'cites','code',NULL,'private:Secrets.swift',
            'human:other',:at,NULL);
          """, arguments: ["at": "2023-11-14T22:13:30.000Z"])
    }
    return store
  }

  private static func maps(_ db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO repo(id,uid,workspace_id,slug) VALUES
          (1100,'01HF7YAT01BSAK5YZEMA9ZG2Y9',17,'platform');
        INSERT INTO app(id,uid,workspace_id,slug,name,repo_id,ref) VALUES
          (1101,'01HF7YAT01Q6TG3MERAJXQ3002',17,'mobile','mobile',1100,'origin/mobile'),
          (1102,'01HF7YAT01MMY3DNVCXJCY0XC5',17,'doc','doc',1100,'origin/api'),
          (1103,'01HF7YAT01N0YQWDEY30BMK5K7',17,'edge','edge',1100,'origin/edge'),
          (1104,'01HF7YAT01C57NC0BQVHTPFZMB',17,'service','service',1100,'origin/service');
        INSERT INTO service(id,uid,workspace_id,slug,name) VALUES
          (1301,'01HF7YAT01R1ETMJWASXV792N2',17,'push service','push service');
        INSERT INTO edge(id,uid,workspace_id,from_app_id,to_app_id,to_service_id,kind,summary)
        VALUES (1201,'01HF7YAT01N1BMRVXEDPDPYETA',17,1101,1102,NULL,'HTTP API','Push'),
          (1202,'01HF7YAT01CC5ZVDX6MRTABWDA',17,1101,NULL,1301,'SDK / v1','Delivery');
        INSERT INTO topic(id,uid,workspace_id,slug,name) VALUES
          (1401,'01HF7YAT01XT4TYC4P6Y2AW235',17,'messaging','Messaging');
        """)
  }

  static func otherDocument(_ docs: inout ExportDocumentSnapshot) {
    let row = ExportDocumentTests.row([
      ("uid", "other-document"), ("slug", "other-rules"), ("previous_slugs", "[]"),
      ("title", "Legacy\n" + String(repeating: "x", count: 121)), ("kind", "design"),
      ("current_rev", "1"), ("archived", "1"), ("created_at", ""), ("updated_at", ""),
    ])
    let revision = ExportDocumentTests.row([
      ("table", "doc_rev"), ("uid", "other-revision"), ("rev", "1"), ("body_md", "Old"),
      ("state", "accepted"), ("actor", "human:acme"), ("created_at", ""),
    ])
    docs.documents.append(ExportDocument(slug: "other-rules", row: row, records: [revision]))
    docs.revisionAllocations.append(
      ExportDocumentTests.row([("slug", "other-rules"), ("next", "2")]))
    docs.commentSequences.append(
      ExportDocumentTests.row([("doc_rev", "other-revision"), ("next", "1")]))
  }

  static func record(
    _ docs: inout ExportDocumentSnapshot, _ index: Int, _ key: String, _ value: String?
  ) {
    let row = docs.documents[0].records[index]
    let keys = ExportFormat.docRecords.first { $0.table == row.value("table") }?.keys ?? []
    docs.documents[0].records[index] = row.replacing(key, with: value, keys: keys)
  }

  static func document(_ docs: inout ExportDocumentSnapshot, _ key: String, _ value: String?) {
    docs.documents[0].row = docs.documents[0].row.replacing(
      key, with: value, keys: ExportFormat.docKeys)
  }

  static func link(_ tree: inout ExportSnapshot, _ index: Int, _ key: String, _ value: String?) {
    tree.links[index] = tree.links[index].replacing(key, with: value, keys: ExportFormat.linkKeys)
  }
}
