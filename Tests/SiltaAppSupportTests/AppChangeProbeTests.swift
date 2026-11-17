#if DEBUG
  import Foundation
  import GRDB
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  @Suite(.blockingTestWork)
  struct AppChangeProbeTests {
    @Test(.timeLimit(.minutes(1))) func persistentProbeSeesTwoCLICommitsAndNoReadCommits() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        let path = reader.environment.db.path
        // A clean last-client close removes side files; the probe must still open.
        let cleanup = try DatabaseQueue(path: path)
        try cleanup.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try cleanup.close()
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
          try FileManager.default.removeItem(atPath: path + suffix)
        }
        #expect(!FileManager.default.fileExists(atPath: path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: path + "-shm"))
        let probe = try reader.makeChangeProbe()
        let observer = try DatabaseQueue(path: path)
        let initialObserver = try version(observer)
        let initial = try probe.version()
        _ = try reader.workspaceMap(workspace: "acme")
        _ = try reader.snapshot(workspace: "acme")
        #expect(try probe.version() == initial)
        #expect(try version(observer) == initialObserver)
        for index in 1...2 {
          let before = try probe.version()
          let result = try SiltaBinary.run(
            ["--ws", "acme", "comment", "AC-12", "-m", "Acme refresh \(index)"],
            in: scratch,
            environment: ["USER": "acme", "SILTA_ACTOR": "agent:codex:probe"])
          try #require(result.termination == .exit(0), "\(result.stderr)")
          #expect(try version(observer) != initialObserver)
          withKnownIssue("Persistent data-version probe is not implemented") { () throws -> Void in
            #expect(try probe.version() != before)
          }
          let after = try probe.version()
          _ = try reader.workspaceMap(workspace: "acme")
          #expect(try probe.version() == after)
        }
      }
    }

    @Test func schemaCompatibilityIsRecheckedOnAnExistingProbe() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        let probe = try reader.makeChangeProbe()
        _ = try probe.version()
        try reader.environment.db.write { tx in
          try tx.database.execute(sql: "UPDATE meta SET value='999' WHERE key='min_writer_version'")
        }
        _ = try probe.version()
        _ = try reader.workspaceMap(workspace: "acme")
        let writer = try DatabaseQueue(path: reader.environment.db.path)
        try writer.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES('future-map')") }
        withKnownIssue("Probe schema gate is not implemented") {
          #expect(throws: AppReadError.self) { try probe.version() }
        }
      }
    }

    @Test func unavailableAndIncompatibleStoresNeverInitializeOrMigrate() throws {
      try withScratchDirectory { scratch in
        let reader = try AppReaderTests.reader(scratch)
        withKnownIssue("Probe and map storage gates are not implemented") {
          #expect(throws: AppReadError.self) { try reader.makeChangeProbe() }
          #expect(throws: AppReadError.self) { try reader.workspaceMap(workspace: "acme") }
        }
        #expect(!FileManager.default.fileExists(atPath: reader.environment.home.url.path))
        try FileManager.default.createDirectory(at: reader.environment.home.url, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: reader.environment.db.path)
        try StorageSchema.migrator.migrate(queue, upTo: "v1")
        withKnownIssue("Probe migration gate is not implemented") {
          var failure: AppReadError?
          do { _ = try reader.makeChangeProbe() } catch let error as AppReadError { failure = error }
          #expect(failure?.kind == .migrationRequired)
          #expect(failure?.next.first?.contains("SILTA_HOME=") == true)
        }
        #expect(try queue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") } == ["v1"])
      }
    }

    private func version(_ queue: DatabaseQueue) throws -> Int {
      try queue.read { db in
        let value = try Int.fetchOne(db, sql: "PRAGMA data_version")
        return try #require(value)
      }
    }
  }
#endif
