#if DEBUG
  import Foundation
  import GRDB
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  @Suite(.blockingTestWork)
  struct AppReaderRecoveryTests {
    @Test func missingStoreDiagnosticKeepsTheSelectedHomeLiteral() throws {
      try withScratchDirectory { scratch in
        let selected = scratch.appending(path: "selected 'space' $(touch escaped); data")
        let reader = try AppReader(
          home: selected, user: AppV2Fixture.user, now: { AppV2Fixture.now })
        let error = try failure(reader)
        #expect(error.kind == .unavailableStore)
        let command = try #require(error.next.first)
        withKnownIssue {
          let result = try SiltaBinary.runProcess(
            URL(filePath: "/bin/sh"),
            ["-c", "silta() { printf '%s' \"$SILTA_HOME\"; }\n" + command], in: scratch)
          #expect(result.termination == .exit(0))
          #expect(result.stdout == selected.path)
          #expect(!FileManager.default.fileExists(atPath: selected.path))
          #expect(
            !FileManager.default.fileExists(atPath: scratch.appending(path: "work/escaped").path))
        }
      }
    }

    @Test func migrationRecoveryChangesOnlyTheSelectedStore() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let defaultDB = scratch.appending(path: "silta-home/silta.db")
        let before = try Data(contentsOf: defaultDB)
        let selected = scratch.appending(path: "selected 'space' $(touch escaped); data")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: selected.appending(path: "silta.db").path)
        try StorageSchema.migrator.migrate(queue, upTo: "v1")
        let reader = try AppReader(
          home: selected, user: AppV2Fixture.user, now: { AppV2Fixture.now })
        let error = try failure(reader)
        #expect(error.kind == .migrationRequired)
        let command = try #require(error.next.first)
        let binary = try SiltaBinary.url()
        withKnownIssue {
          let result = try SiltaBinary.runProcess(
            URL(filePath: "/bin/sh"),
            ["-c", "silta() { " + shellWord(binary.path) + " \"$@\"; }\n" + command],
            in: scratch,
            environment: [
              "USER": AppV2Fixture.user, "SILTA_NOW": "2026-11-16T12:00:00.000Z",
              "SILTA_ID_SEED": "951",
            ])
          #expect(result.termination == .exit(0))
          #expect(
            try queue.read { try StorageSchema.migrator.appliedIdentifiers($0) }
              == Set(StorageSchema.migrator.migrations))
          #expect(try Data(contentsOf: defaultDB) == before)
          #expect(
            !FileManager.default.fileExists(atPath: scratch.appending(path: "work/escaped").path))
        }
      }
    }

    private func failure(_ reader: AppReader) throws -> AppReadError {
      var failure: AppReadError?
      do { _ = try reader.workspaces() } catch let error as AppReadError { failure = error }
      return try #require(failure)
    }
  }
#endif
