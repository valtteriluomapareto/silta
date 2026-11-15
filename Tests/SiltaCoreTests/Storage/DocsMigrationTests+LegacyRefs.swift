import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension DocsMigrationTests {
  @Test func backfillFreezesLegacyRefEncodingAndJSONBytes() throws {
    try withScratchDirectory { home in
      let store = try Self.copyFixture(to: home)
      try DatabaseQueue(path: store.path).write { db in
        try db.execute(sql: "UPDATE service SET slug='Push API/雪'")
        try db.execute(sql: "UPDATE edge SET kind='HTTP API/β' WHERE id=1")
      }
      try store.initialize()
      let metadata = try store.read {
        try String.fetchOne($0, sql: "SELECT about_refs FROM doc_rev WHERE id=12")
      }
      #expect(
        metadata
          == "[\"app:mobile\",\"edge:mobile/api/HTTP%20API%2F%CE%B2\",\"service:Push%20API%2F%E9%9B%AA\"]"
      )
      #expect(
        try store.read {
          try Int.fetchOne(
            $0, sql: "SELECT count(*) FROM doc_rev WHERE id IN (11,13) AND about_refs IS NULL")
        } == 2)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT body_md FROM doc_rev WHERE id=12") }
          == "Keep unknown categories visible.")
    }
  }
}
