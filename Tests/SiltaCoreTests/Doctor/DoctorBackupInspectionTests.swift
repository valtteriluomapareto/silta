import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct DoctorBackupInspectionTests {
  @Test(arguments: [false, true]) func emptyDatabaseRetainsUncertainBackupRecovery(unreadable: Bool)
    async throws
  {
    await withKnownIssue("#15: empty database with uncertain backups") {
      try await withScratchDirectory { home in
        do {
          let store = StorageSchemaTests.store(home)
          try store.initialize()
          _ = try store.write { _ in () }
        }
        try Data().write(to: home.appending(path: "silta.db"))
        if unreadable {
          let directory = home.appending(path: "backups")
          try FileManager.default.removeItem(at: directory)
          try Data("Acme unavailable storage".utf8).write(to: directory)
        }
        let git = ScriptedGitRunner(script: [
          (
            GitRequest(arguments: ["--version"], directory: URL(filePath: "/")),
            .success(GitResult(termination: .exit(0), stdout: Data("git version 2.50\n".utf8)))
          )
        ])
        let report = await DoctorService.inspect(
          store: StorageSchemaTests.store(home), home: home,
          git: git, at: StorageSchemaTests.instant)
        let check = try #require(report.checks.first { $0.id == "database.schema" })
        #expect(check.status == .fail)
        #expect(!check.next.contains("silta init"))
        #expect(check.next.first?.hasPrefix("/bin/ls -l ") == true)
      }
    }
  }

  @Test(arguments: ["meta", "grdb_migrations"]) func nonemptyIncompleteSchemaRequiresInspection(
    table: String
  ) async throws {

    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      _ = try store.write { _ in () }
      let queue = try DatabaseQueue(path: store.path)
      try await queue.write { db in
        if table == "meta" {
          try db.execute(sql: "DROP TABLE meta")
        } else {
          try db.execute(sql: "DROP TABLE grdb_migrations")
        }
      }
      let git = ScriptedGitRunner(script: [
        (
          GitRequest(arguments: ["--version"], directory: URL(filePath: "/")),
          .success(GitResult(termination: .exit(0), stdout: Data("git version 2.50\n".utf8)))
        )
      ])
      let report = await DoctorService.inspect(
        store: store, home: home, git: git, at: StorageSchemaTests.instant)
      let check = try #require(report.checks.first { $0.id == "database.schema" })
      #expect(check.status == .fail)
      #expect(!check.next.contains("silta init"))
      #expect(check.next.first?.hasPrefix("/bin/ls -l ") == true)
      #expect(check.message.contains("human"))
    }

  }

  @Test(arguments: [false, true]) func unavailableInventoryNeverImpliesEmptyStorage(missing: Bool)
    async throws
  {

    try await withScratchDirectory { home in
      if !missing { try StorageSchemaTests.store(home).initialize() }
      let backups = home.appending(path: "backups")
      if FileManager.default.fileExists(atPath: backups.path) {
        try FileManager.default.removeItem(at: backups)
      }
      // A file at the directory's location is deterministic and cannot be enumerated.
      try Data("Acme backup storage unavailable".utf8).write(to: backups)
      let report = await DoctorService.inspect(
        store: StorageSchemaTests.store(home), home: home,
        git: ScriptedGitRunner(script: [
          (
            GitRequest(arguments: ["--version"], directory: URL(filePath: "/")),
            .success(GitResult(termination: .exit(0), stdout: Data("git version 2.50\n".utf8)))
          )
        ]), at: StorageSchemaTests.instant)
      #expect(report.checks.first { $0.id == "data.backup" }?.status == .warning)
      if missing {
        let check = try #require(report.checks.first { $0.id == "database.integrity" })
        #expect(!check.next.contains("silta init"))
        #expect(check.next.first?.hasPrefix("/bin/ls -l ") == true)
      }
    }

  }
}
