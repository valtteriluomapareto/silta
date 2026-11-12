import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct LegacyMapIdentityTests {
  @Test func legacyIdentitiesAndAttachmentsSurviveUpgradeAndEditing() throws {
    try withScratchDirectory { home in
      let store = try DocsMigrationTests.copyFixture(to: home)
      let queue = try DatabaseQueue(path: store.path)
      try queue.write { db in
        try db.execute(sql: "UPDATE service SET slug='push/legacy %雪' WHERE id=1")
        try db.execute(sql: "UPDATE edge SET kind='HTTP/API %2F 雪' WHERE id=1")
      }
      let identities = try store.read { db in
        try ["edge", "service", "link"].map {
          try String.fetchAll(db, sql: "SELECT id || ':' || uid FROM \($0) ORDER BY id")
        }
      }
      try store.initialize()
      try store.read { (db: Database) throws in
        #expect(
          try TaskLinkTarget.render(
            Row(["to_kind": "service", "to_id": 1, "to_ext": nil, "anchor": nil]), in: db)
            == "service:push%2Flegacy%20%25%E9%9B%AA")
        #expect(
          try TaskLinkTarget.render(
            Row(["to_kind": "edge", "to_id": 1, "to_ext": nil, "anchor": nil]), in: db)
            == "edge:mobile/api/HTTP%2FAPI%20%252F%20%E9%9B%AA")
      }
      let yaml = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      try AcmeDocAttachments.apply(
        yaml.replacingOccurrences(of: "\"Acme\"", with: "\"Changed\""), to: store)
      try store.read { (db: Database) throws in
        #expect(
          try String.fetchOne(db, sql: "SELECT slug FROM service WHERE id=1") == "push/legacy %雪")
        #expect(
          try String.fetchOne(db, sql: "SELECT kind FROM edge WHERE id=1") == "HTTP/API %2F 雪")
        #expect(try String.fetchOne(db, sql: "SELECT name FROM workspace") == "Changed")
        #expect(
          try ["edge", "service", "link"].map {
            try String.fetchAll(db, sql: "SELECT id || ':' || uid FROM \($0) ORDER BY id")
          } == identities)
      }
    }
  }

  @Test(arguments: ["push service", "push/legacy", "-push"])
  func newlyCreatedServiceRequiresIdentifier(slug: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let before = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let edited = AcmeDocAttachments.yaml().replacingOccurrences(
        of: "services: [push]", with: "services: [push, \(try WorkspaceConfig.json(slug))]")
      #expect(throws: WorkspaceError.self) { try AcmeDocAttachments.apply(edited, to: store) }
      #expect(try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") } == before)
    }
  }

  @Test(arguments: ["HTTP API", "http/api", "http-"])
  func newlyCreatedEdgeRequiresIdentifier(kind: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let before = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let edited = AcmeDocAttachments.yaml().replacingOccurrences(
        of: "kind: sdk", with: "kind: \(try WorkspaceConfig.json(kind))")
      #expect(throws: WorkspaceError.self) { try AcmeDocAttachments.apply(edited, to: store) }
      #expect(try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") } == before)
    }
  }
}
