import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocLegacyMapByteTests {
  @Test(arguments: ["service", "edge"], [false, true])
  func retainedNamesRenderResolveAndKeepTheirActualTarget(kind: String, sibling: Bool) async throws
  {
    await withKnownIssue("SI-126/38: preserve archive and literal identity contracts") {
      try await withScratchDirectory { home in
        let store = try Self.fixture(home, kind: kind, sibling: sibling)
        let ref = kind == "service" ? "service:push%00tail" : "edge:api/service:push/sdk%00tail"
        let original = try Self.target(store)
        let rendered = try store.read { db in
          try TaskLinkTarget.render(Self.link(db), in: db)
        }
        #expect(rendered == ref)
        var resolved: Int64?
        var resolution: (any CodedError)?
        do {
          resolved = try store.read { try TaskLinkTarget.map(ref, workspace: 1, in: $0).id }
        } catch let error as any CodedError { resolution = error }
        #expect(resolution == nil && resolved == original)
        var result: DocWriteResult?
        var failure: (any CodedError)?
        var request = DocEditRequest(slug: "rules")
        request.keepBody = true
        do {
          result = try await DocWritePolicyTests.service(home, store).edit(request, input: nil)
        } catch let error as any CodedError { failure = error }
        #expect(failure == nil && result?.ref == "doc:rules@2")
        #expect(try Self.target(store) == original)
        if result != nil {
          let revision = try DocProposalServiceTests.row(store, revision: 2)
          #expect(revision["about_refs"] as String == (try WorkspaceConfig.json([ref])))
          #expect(revision["body_md"] as String == "Private Acme body")
        }
      }
    }
  }

  @Test(arguments: ["service", "edge"])
  func invalidLegacyNameUTF8RefusesWithoutMutation(kind: String) throws {
    withKnownIssue("SI-126/38: preserve archive and literal identity contracts") {
      try withScratchDirectory { home in
        let store = try Self.fixture(home, kind: kind, sibling: false)
        try store.write {
          try $0.database.execute(
            sql:
              "UPDATE \(kind) SET \(kind == "service" ? "slug" : "kind")=CAST(? AS TEXT) WHERE id=1",
            arguments: [Data([65, 255, 66])])
        }
        let before = try DocVerificationPreparationTests.truth(store)
        _ = try store.read { (db: Database) throws in
          #expect(throws: StorageError.corrupt) {
            _ = try TaskLinkTarget.render(Self.link(db), in: db)
          }
        }
        #expect(try DocVerificationPreparationTests.truth(store) == before)
      }
    }
  }

  @Test(arguments: ["title", "kind"])
  func keepBodyRetainsOwnedMetadataAfterNUL(field: String) async throws {
    await withKnownIssue("SI-126/38: preserve archive and literal identity contracts") {
      try await withScratchDirectory { home in
        let store = try AcmeDocAttachments.make(in: home)
        try AcmeDocAttachments.attach("rules", to: "service", in: store)
        let bytes = Data((field == "title" ? "Rules\u{0}tail" : "reference\u{0}tail").utf8)
        try store.write {
          try $0.database.execute(
            sql: "UPDATE doc SET \(field)=CAST(? AS TEXT)", arguments: [bytes])
          try $0.database.execute(
            sql: "UPDATE doc_rev SET \(field)=CAST(? AS TEXT)", arguments: [bytes])
        }
        var request = DocEditRequest(slug: "rules")
        request.keepBody = true
        var result: DocWriteResult?
        var failure: (any CodedError)?
        do {
          result = try await DocWritePolicyTests.service(home, store).edit(request, input: nil)
        } catch let error as any CodedError { failure = error }
        #expect(failure == nil && result?.ref == "doc:rules@2")
        #expect(
          try store.read { try Data.fetchOne($0, sql: "SELECT CAST(\(field) AS BLOB) FROM doc") }
            == bytes)
        #expect(
          try store.read {
            try Data.fetchOne($0, sql: "SELECT CAST(\(field) AS BLOB) FROM doc_rev WHERE rev=2")
          } == bytes)
      }
    }
  }

  static func fixture(_ home: URL, kind: String, sibling: Bool) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: home)
    try AcmeDocAttachments.attach("rules", to: kind, in: store)
    try store.write {
      if kind == "service" {
        try $0.database.execute(
          sql: "UPDATE service SET slug=CAST(? AS TEXT) WHERE id=1",
          arguments: [Data("push\u{0}tail".utf8)])
        if sibling {
          try $0.database.execute(
            sql: """
              INSERT INTO service(uid,workspace_id,slug,name)
              VALUES('plain-service',1,'push','Acme sibling')
              """)
        }
      } else {
        try $0.database.execute(
          sql: "UPDATE edge SET kind=CAST(? AS TEXT) WHERE id=1",
          arguments: [Data("sdk\u{0}tail".utf8)])
        if sibling {
          try $0.database.execute(
            sql: """
              INSERT INTO edge(uid,workspace_id,from_app_id,to_service_id,kind,summary)
              SELECT 'plain-edge',workspace_id,from_app_id,to_service_id,'sdk','Acme sibling'
              FROM edge WHERE id=1
              """)
        }
      }
    }
    return store
  }

  private static func link(_ db: Database) throws -> Row {
    try #require(
      try Row.fetchOne(db, sql: "SELECT * FROM link WHERE from_kind='doc' AND rel='about'"))
  }

  private static func target(_ store: DatabaseStore) throws -> Int64 {
    try store.read { db in try #require(try Self.link(db)["to_id"] as Int64?) }
  }
}
