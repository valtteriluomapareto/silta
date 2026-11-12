import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct MapReferenceTests {
  static func resolve(_ raw: String, in db: Database) throws -> TaskLinkTarget {
    let task = try TaskService.lookup("AC-1", workspace: "acme", in: db)
    return try TaskLinkTarget.resolve(raw, source: task, workspace: "acme", in: db)
  }

  @Test func typedMapReferencesRoundTripWithoutMergingAppAndServiceTargets() throws {
    try withScratchDirectory { home in
      let store = try DocsMigrationTests.copyFixture(to: home)
      try store.initialize()
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO service(uid,workspace_id,slug,name) VALUES('same-slug',1,'api','API service');
            INSERT INTO edge(uid,workspace_id,from_app_id,to_service_id,kind,summary)
              VALUES('service-edge',1,1,2,'http-api','Different target');
            UPDATE service SET slug='push/legacy %2F 雪' WHERE id=1;
            UPDATE edge SET kind='HTTP/API %2F 雪' WHERE id=2;
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
            INSERT INTO service(uid,workspace_id,slug,name) VALUES('foreign',2,'foreign','Foreign');
            """)
      }
      let refs = [
        "app:mobile", "topic:messaging", "service:api",
        "edge:mobile/api/http-api", "edge:mobile/service:api/http-api",
        "service:push%2Flegacy%20%252F%20%E9%9B%AA",
        "edge:api/service:push%2Flegacy%20%252F%20%E9%9B%AA/HTTP%2FAPI%20%252F%20%E9%9B%AA",
      ]
      try store.read { db in
        for ref in refs {
          #expect(try Self.resolve(ref, in: db).rendered(in: db) == ref)
        }
        let app = try Self.resolve(refs[3], in: db)
        let service = try Self.resolve(refs[4], in: db)
        #expect(app.id != service.id)
        for raw in [
          "service:foreign", "edge:mobile/service:foreign/http-api", "edge:api/mobile/http-api",
        ] {
          do {
            _ = try Self.resolve(raw, in: db)
            Issue.record("Missing map target resolved")
          } catch let error as any CodedError {
            #expect(error.code == .notFound)
            #expect(error.next == ["silta --ws 'acme' ws show"])
            if raw == "service:foreign" {
              ReservedAppIdentityTests.check(error, golden: "missing-map-ref-error.txt")
            }
          }
        }
      }
    }
  }

  @Test(arguments: [
    "service:", "service:push%", "service:push%2", "service:push%GG", "service:push%2flegacy",
    "service:%70ush", "service:push service", "service:%FF", "service:%C0%AF",
    "edge:mobile/api", "edge:mobile/api/http-api/extra", "edge:mobile//http-api",
    "edge:mobile/api/", "edge:mobile/api/http%2dapi", "edge:mobile/api/HTTP API",
    "edge:mobile/service:/http-api", "edge:mobile/api/%FF",
  ])
  func malformedAndNoncanonicalMapReferencesAreInvalid(raw: String) throws {
    try withScratchDirectory { home in
      let store = try DocsMigrationTests.copyFixture(to: home)
      try store.initialize()
      try store.read { db in
        do {
          _ = try Self.resolve(raw, in: db)
          Issue.record("Invalid map reference resolved")
        } catch let error as any CodedError {
          #expect(error.code == .invalid)
        }
      }
    }
  }
}
