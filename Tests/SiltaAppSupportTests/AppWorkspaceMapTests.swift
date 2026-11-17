#if DEBUG
  import Foundation
  import GRDB
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  @Suite(.blockingTestWork)
  struct AppWorkspaceMapTests {
    @Test func readsSeedMapAndCanonicalAttachments() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        do {
          let map = try reader.workspaceMap(workspace: "acme")
          #expect(map.apps.map(\.slug) == ["acme-backend", "acme-mobile", "acme-web"])
          #expect(map.apps.map(\.attachment) == map.apps.map { "app:" + $0.slug })
          #expect(map.apps.first?.repo == "backend")
          #expect(map.apps.first?.ref == "origin/main")
          #expect(map.apps.first?.summary == "API for mobile and web")
          #expect(map.services.map(\.attachment) == ["service:payments", "service:push"])
          #expect(
            map.connections.map(\.attachment) == [
              "edge:acme-backend/service:payments/http-api",
              "edge:acme-mobile/acme-backend/http-api",
              "edge:acme-mobile/service:push/sdk", "edge:acme-web/acme-backend/graphql",
            ])
          #expect(map.connections.first?.summary == "Card payments")
          #expect(map.connections.first?.source == "acme-backend")
          #expect(map.connections.first?.target == "service:payments")
          #expect(map.connections.first?.kind == "http-api")
          #expect(map.connections.first?.codeReferences == [])
        }
      }
    }

    @Test func projectsEncodedIdentitiesAndCodeWithoutRoundTrippingYAML() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        try reader.environment.db.write { tx in
          try tx.database.execute(
            sql: "UPDATE service SET slug='pay/ments%é' WHERE slug='payments'")
          try tx.database.execute(
            sql: """
              UPDATE edge SET kind='HTTP/v2',code_refs=?
              WHERE from_app_id=(SELECT id FROM app WHERE slug='acme-backend')
              """,
            arguments: ["[\"acme-backend:Sources/Pay.swift#L4\"]"])
        }
        do {
          let map = try reader.workspaceMap(workspace: "acme")
          let edge = try #require(map.connections.first)
          #expect(edge.attachment == "edge:acme-backend/service:pay%2Fments%25%C3%A9/HTTP%2Fv2")
          #expect(edge.codeReferences == ["acme-backend:Sources/Pay.swift#L4"])
          #expect(map.services.first?.attachment == "service:pay%2Fments%25%C3%A9")
        }
      }
    }

    @Test func emptyMapAndUnknownWorkspaceAreDistinct() throws {
      try withScratchDirectory { scratch in
        let reader = try AppReaderTests.reader(scratch)
        let config = try WorkspaceConfig.parse(
          "workspace: {slug: acme, name: Acme, task_prefix: AC}")
        try reader.environment.db.write {
          try config.apply(in: $0, ids: SeededIDGenerator(seed: 9), at: AppV2Fixture.now)
        }
        #expect(try reader.workspaceMap(workspace: "acme").apps.isEmpty)
        do {
          #expect(throws: AppReadError.self) { try reader.workspaceMap(workspace: "absent") }
        }
      }
    }
    @Test(arguments: [
      "UPDATE service SET slug=CAST(x'80' AS TEXT) WHERE slug='payments'",
      "UPDATE edge SET kind=CAST(x'80' AS TEXT)",
      "UPDATE edge SET code_refs='{}'",
    ]) func corruptMapValuesRefuseInsteadOfRepairing(_ sql: String) throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        try reader.environment.db.write { try $0.database.execute(sql: sql) }
        var failure: AppReadError?
        do { _ = try reader.workspaceMap(workspace: "acme") } catch let error as AppReadError {
          failure = error
        }
        #expect(failure?.message == StorageError.corrupt.message)
      }
    }
    @Test(arguments: [
      "UPDATE app SET slug=CAST(x'80' AS TEXT) WHERE slug='acme-mobile'",
      "UPDATE edge SET code_refs=CAST(x'"
        + "5b2261636d652d6d6f62696c653a536f75726365732f802e7377696674225d"
        + "' AS TEXT)",
    ]) func referenceBytesAreNeverRepaired(_ sql: String) throws {
      do {
        try withScratchDirectory { scratch in
          try AppFixtures.seed(in: scratch)
          let reader = try AppReaderTests.reader(scratch)
          try reader.environment.db.write { try $0.database.execute(sql: sql) }
          #expect(throws: AppReadError.self) { try reader.workspaceMap(workspace: "acme") }
        }
      }
    }
  }
#endif
