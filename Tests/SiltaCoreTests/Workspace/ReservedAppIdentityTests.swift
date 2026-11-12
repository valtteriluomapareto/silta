import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct ReservedAppIdentityTests {
  @Test(arguments: ["doc", "edge", "service"])
  func newlyCreatedReservedAppsRefuseAtomically(slug: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let before = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let yaml = AcmeDocAttachments.yaml().replacingOccurrences(of: "api", with: slug)
      do {
        try AcmeDocAttachments.apply(yaml, to: store)
        Issue.record("New reserved app was accepted")
      } catch let error as WorkspaceError {
        #expect(error.code == .invalid)
        if slug == "doc" { Self.check(error, golden: "reserved-app-error.txt") }
      }
      #expect(try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") } == before)
    }
  }

  @Test(arguments: ["doc", "edge", "service"])
  func legacyNamesAndExplicitCodeLinksSurviveEditAndFreshRestore(slug: String) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "source")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      let store = try DocsMigrationTests.copyFixture(to: home)
      try store.initialize()
      try store.write { tx in
        try tx.database.execute(
          sql: """
            DELETE FROM link WHERE from_kind='doc';
            DELETE FROM doc_rev;
            DELETE FROM doc;
            UPDATE workspace SET settings='{}';
            UPDATE app SET slug=? WHERE id=1;
            UPDATE service SET slug='push/legacy %雪' WHERE id=1;
            UPDATE edge SET kind='HTTP API' WHERE id=1;
            """, arguments: [slug])
      }
      let yaml = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let identities = try Self.identities(in: store)
      try AcmeDocAttachments.apply(
        yaml.replacingOccurrences(of: "\"Acme\"", with: "\"Changed\""), to: store)
      #expect(try Self.identities(in: store) == identities)
      let service = TaskService(
        environment: try TaskServiceTests.environment(home), workspace: "acme")
      _ = try service.link("AC-1", target: "code:\(slug):src/Acme.swift")
      _ = try service.link("AC-1", target: "code:\(slug)@feature/x:src/Branch.swift")
      let linked = try service.show("AC-1").links
      #expect(linked.contains { $0.target == "code:\(slug):src/Acme.swift" })
      do {
        _ = try service.link("AC-1", target: "\(slug):src/Implicit.swift")
        Issue.record("Reserved typed prefix fell back to code")
      } catch let error as any CodedError {
        #expect(error.code == (slug == "doc" ? .notFound : .invalid))
        if slug == "edge" { Self.check(error, golden: "task-map-target-error.txt") }
      }
      do {
        _ = try service.link("AC-1", target: "\(slug)@feature/x:src/Implicit.swift")
        Issue.record("Reserved app at an explicit branch accepted implicit code")
      } catch let error as any CodedError {
        #expect(error.code == .invalid)
        #expect(error.next == ["silta task link --help"])
        if slug == "doc" { Self.check(error, golden: "reserved-code-prefix-error.txt") }
      }
      #expect(try service.show("AC-1").links == linked)
      let files = try ExportTreeTests.render(store)
      let tree = try RestoreSupport.write(files, to: scratch.appending(path: "tree/acme"))
      let freshHome = scratch.appending(path: "fresh")
      let fresh = ExportFixture.store(freshHome)
      try fresh.initialize()
      _ = try RestoreSupport.restore(tree, into: fresh, home: freshHome)
      ExportTreeTests.expectSame(try ExportTreeTests.render(fresh), files)
      #expect(try Self.identities(in: fresh) == identities)
      let restored = TaskService(
        environment: try TaskServiceTests.environment(freshHome), workspace: "acme")
      #expect(try restored.show("AC-1").links == linked)
    }
  }

  @Test(arguments: ["edge", "service"])
  func preexistingTaskLinksProtectMapTargets(kind: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO task(id,uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
              VALUES(1,'task',1,1,'Work','todo','human:acme','','');
            INSERT INTO link(
            uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
              VALUES('task-link',1,'task',1,'cites',?,1,'human:acme','');
            """, arguments: [kind])
      }
      let before = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      #expect(throws: WorkspaceError.self) {
        try AcmeDocAttachments.apply(AcmeDocAttachments.yaml(removing: kind), to: store)
      }
      #expect(try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") } == before)
    }
  }

  @Test func reservesNamesWithANewWriterFloor() throws {
    try withScratchDirectory { home in
      let queue = try DatabaseQueue(path: home.appending(path: "silta.db").path)
      try StorageSchema.migrator.migrate(queue, upTo: "v5")
      try StorageSchemaTests.store(home).initialize()
      #expect(DatabaseStore.writerVersion >= 6)
      #expect(
        try queue.read {
          try Int.fetchOne($0, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
        } == 6)
    }
  }

  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func actualMetadataWriterCannotWriteAfterNamespaceUpgrade() throws {
    let binary = try #require(ProcessInfo.processInfo.environment["SILTA_PRIOR_BINARY"])
    try withScratchDirectory { home in
      let store = try DocsMigrationTests.copyFixture(to: home)
      let args = ["--ws", "acme", "task", "add", "Prior writer"]
      let environment = ["SILTA_HOME": home.path, "SILTA_ACTOR": "agent:codex:acme"]
      let before = try SiltaBinary.runProcess(
        URL(filePath: binary), args, in: home, environment: environment)
      try #require(before.termination == .exit(0))
      try #require(
        try store.read {
          try Int.fetchOne($0, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
        } == 5)
      try store.initialize()
      let count = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") }
      let after = try SiltaBinary.runProcess(
        URL(filePath: binary), ["--json"] + args, in: home, environment: environment)
      #expect(after.termination == .exit(9))
      #expect(after.stdout.contains("Database requires a newer version of silta."))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == count)
    }
  }

  static func check(_ error: any CodedError, golden: String) {
    let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
    let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
    Golden.forTests().check(text.stderr + json.stdout, golden)
  }

  private static func identities(in store: DatabaseStore) throws -> [[String]] {
    try store.read { db in
      try ["app", "service", "edge"].map { table in
        try String.fetchAll(
          db,
          sql:
            "SELECT uid || ':' || \(table == "edge" ? "kind" : "slug") FROM \(table) ORDER BY uid")
      }
    }
  }
}
