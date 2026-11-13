import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocVerificationEvidenceTests {
  @Test func acceptingAnEdgeRecordsBothConfiguredAppCommits() throws {
    try withScratchDirectory { home in
      let store = try DocsMigrationTests.copyFixture(to: home)
      try store.initialize()
      _ = try DocStoreTests.accept(
        DocDraft(slug: "push-rules", body: "Retain the fallback."), in: store,
        ids: SeededIDGenerator(seed: 71))
      let raw = try #require(
        try store.read {
          try String.fetchOne(
            $0, sql: "SELECT app_shas FROM doc_verification ORDER BY id DESC LIMIT 1")
        })
      let snapshots = try JSONDecoder().decode([[String: String]].self, from: Data(raw.utf8))
      #expect(
        snapshots == [
          ["app": "api", "ref": "origin/api", "sha": String(repeating: "f", count: 40)],
          ["app": "mobile", "ref": "origin/mobile", "sha": String(repeating: "f", count: 40)],
        ])
    }
  }

  @Test func shippedV5BackfillHasLiteralBytesAndUnknownHistory() throws {
    try withScratchDirectory { home in
      let store = try DocsMigrationTests.copyFixture(to: home)
      let queue = try DatabaseQueue(path: store.path)
      try StorageSchema.migrator.migrate(queue, upTo: "v5")
      try queue.read { db in
        #expect(
          try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
            == ["v1", "v2", "v3", "v4", "v5"])
        let current = try #require(
          try Row.fetchOne(db, sql: "SELECT title,kind,about_refs FROM doc_rev WHERE rev=2"))
        #expect(current["title"] as String == "Push rules")
        #expect(current["kind"] as String == "contract")
        #expect(
          current["about_refs"] as String
            == #"["app:mobile","edge:mobile/api/http-api","service:push"]"#)
        for number in [1, 3] {
          let old = try #require(
            try Row.fetchOne(
              db,
              sql: "SELECT title,kind,about_refs FROM doc_rev WHERE rev=?", arguments: [number]))
          #expect(old["title"] as String? == nil)
          #expect(old["kind"] as String? == nil)
          #expect(old["about_refs"] as String? == nil)
        }
      }
    }
  }
}
