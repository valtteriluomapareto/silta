import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct DogfoodWorkspaceTests {
  static let remote = "https://github.com/valtteriluomapareto/silta.git"

  @Test func shippedConfigAppliesWithoutReplacingScannedPath() throws {
    withKnownIssue("The shipped YAML erases the scanned remote") {
      try Self.apply()
    }
  }

  static func apply() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(
      contentsOf: root.appending(path: "docs/dogfood/workspace.yaml"), encoding: .utf8)
    let config = try WorkspaceConfig.parse(text)
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix,settings)
            VALUES('acme-silta','silta','Acme','SI','{"future":42}');
            INSERT INTO repo(uid,workspace_id,slug,remote_url)
            VALUES('acme-silta-repo',1,'silta',?);
            INSERT INTO repo_path(repo_id,path) VALUES(1,?);
            """, arguments: [remote, home.path])
      }
      try store.write {
        try config.apply(in: $0, ids: SeededIDGenerator(seed: 7), at: StorageSchemaTests.instant)
      }
      try store.read { db in
        let path = try String.fetchOne(db, sql: "SELECT path FROM repo_path")
        let uid = try String.fetchOne(db, sql: "SELECT uid FROM repo")
        let remote = try String.fetchOne(db, sql: "SELECT remote_url FROM repo")
        let apps = try Int.fetchOne(db, sql: "SELECT count(*) FROM app")
        let ref = try String.fetchOne(db, sql: "SELECT ref FROM app")
        let repos = try Int.fetchOne(db, sql: "SELECT count(*) FROM repo")
        let topics = try String.fetchAll(db, sql: "SELECT slug FROM topic")
        let settings = try String.fetchOne(db, sql: "SELECT settings FROM workspace")
        #expect(path == home.path && uid == "acme-silta-repo" && remote == Self.remote)
        #expect(apps == 1 && repos == 1 && topics == ["dogfood"] && ref == "origin/main")
        #expect(settings == "{\"future\":42}")
      }
    }
    #expect(!text.contains("proposals:") && !text.contains("ask_about:"))
  }
}
