import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct DoctorServiceTests {
  private let now = StorageSchemaTests.instant

  private func inspect(_ home: URL, gitFailure: Bool = false, at: Date? = nil) async -> DoctorReport
  {
    let git = ScriptedGitRunner(script: [
      (
        GitRequest(arguments: ["--version"], directory: URL(filePath: "/")),
        gitFailure
          ? .failure(SeamError.gitUnavailable)
          : .success(GitResult(termination: .exit(0), stdout: Data("git version 2.50.0\n".utf8)))
      )
    ])
    return await DoctorService.inspect(
      store: StorageSchemaTests.store(home), home: home, git: git, at: at ?? now)
  }

  @Test func corruptDatabaseAndGitFailuresAreBothReported() async throws {
    try await withScratchDirectory { home in
      try Data("acme-private-invalid-sqlite".utf8).write(to: home.appending(path: "silta.db"))
      let before = try Data(contentsOf: home.appending(path: "silta.db"))
      let report = await inspect(home, gitFailure: true)
      #expect(
        report.checks.filter { $0.status == .fail }.map(\.id) == [
          "database.integrity", "git.version",
        ])
      #expect(!report.text.contains("acme-private"))
      #expect(!report.text.contains("next: silta doctor"))
      #expect(try Data(contentsOf: home.appending(path: "silta.db")) == before)
    }
  }

  @Test(arguments: ["old", "future", "incompatible", "diverged", "missing-meta"])
  func schemaDiagnosisNeverMigrates(kind: String) async throws {
    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      let queue = try DatabaseQueue(path: store.path)
      try await queue.write { db in
        switch kind {
        case "old": try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v3'")
        case "future": try db.execute(sql: "INSERT INTO grdb_migrations VALUES('future')")
        case "incompatible":
          try db.execute(sql: "UPDATE meta SET value='999' WHERE key='min_writer_version'")
        case "diverged":
          try db.execute(sql: "INSERT INTO grdb_migrations VALUES('future')")
          try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v1'")
        default: try db.execute(sql: "DELETE FROM meta WHERE key='min_writer_version'")
        }
      }
      let before = try await queue.read {
        try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
      }
      let report = await inspect(home)
      #expect(
        report.checks.first { $0.id == "database.schema" }?.status
          == (kind == "future" ? .warning : .fail))
      #expect(
        try await queue.read {
          try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        } == before)
      if kind == "old" {
        #expect(report.checks.first { $0.id == "database.schema" }?.next == ["silta init"])
      }
      if kind != "future" {
        #expect(report.checks.first { $0.id == "data.claims" }?.status == .skipped)
      }
    }
  }

  @Test func lateQueryFailureRetainsIndependentChecks() async throws {
    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      _ = try store.write { _ in () }
      let queue = try DatabaseQueue(path: store.path)
      try await queue.write { try $0.execute(sql: "ALTER TABLE task DROP COLUMN claimed_at") }
      let report = await inspect(home)
      for id in [
        "database.integrity", "database.foreign_keys", "database.schema", "database.wal",
        "git.repos", "data.backup",
      ] {
        #expect(report.checks.first { $0.id == id }?.status == .pass)
      }
      #expect(report.checks.first { $0.id == "data.claims" }?.status == .fail)
    }
  }

  @Test func foreignKeyViolationIsRed() async throws {
    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      var config = Configuration()
      config.foreignKeysEnabled = false
      let queue = try DatabaseQueue(path: store.path, configuration: config)
      try await queue.write {
        try $0.execute(sql: "INSERT INTO repo(uid,workspace_id,slug) VALUES('orphan',999,'acme')")
      }
      let report = await inspect(home)
      #expect(report.checks.first { $0.id == "database.foreign_keys" }?.status == .fail)
    }
  }

  @Test(arguments: [-1.0, 0.0, 1.0]) func agesAndDeadPathsDoNotChangeTruth(excess: Double)
    async throws
  {
    try await withScratchDirectory { home in
      let (repo, queue) = try seedClaim(home, excess: excess)
      let report = await inspect(home)
      #expect(
        report.checks.first { $0.id == "git.fetch" }?.status == (excess <= 0 ? .pass : .warning))
      #expect(
        report.checks.first { $0.id == "data.claims" }?.status == (excess < 0 ? .pass : .warning))
      #expect(report.checks.first { $0.id == "git.repos" }?.status == .pass)
      try FileManager.default.removeItem(at: repo.appending(path: ".git"))
      let dead = await inspect(home)
      #expect(dead.checks.first { $0.id == "git.repos" }?.status == .fail)
      #expect(dead.checks.first { $0.id == "git.overrides" }?.status == .warning)
      #expect(!dead.text.contains("private body"))
      #expect(
        dead.checks.first { $0.id == "git.repos" }?.next.contains { $0.contains(repo.path) } == true
      )
      #expect(
        dead.checks.first { $0.id == "git.overrides" }?.next.allSatisfy {
          !$0.hasPrefix("silta where")
        } == true)
      try FileManager.default.removeItem(at: repo)
      let missing = await inspect(home)
      #expect(missing.checks.first { $0.id == "git.overrides" }?.status == .warning)
      try await queue.write {
        try $0.execute(sql: "UPDATE repo_path SET fetched_at='invalid'")
        try $0.execute(sql: "UPDATE task SET claimed_at=NULL")
      }
      let invalid = await inspect(home)
      #expect(invalid.checks.first { $0.id == "git.fetch" }?.status == .pass)
      #expect(invalid.checks.first { $0.id == "data.claims" }?.status == .warning)
      #expect(
        try await queue.read { try String.fetchOne($0, sql: "SELECT claimed_by FROM task") }
          == "agent:codex:acme")
      #expect(
        try await queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM worktree_override") }
          == 1)
    }
  }

  @Test func deadRepositoryEvidenceSelectsOnlyTheBrokenRegistration() async throws {
    try await withScratchDirectory { home in
      let (dead, queue) = try seedClaim(home, excess: 0)
      let healthy = home.appending(path: "healthy/.git")
      try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
      try await queue.write { db in
        try db.execute(sql: "INSERT INTO repo(uid,workspace_id,slug) VALUES('healthy',1,'healthy')")
        try db.execute(
          sql: "INSERT INTO repo_path(repo_id,path) VALUES(2,?)",
          arguments: [healthy.deletingLastPathComponent().path])
      }
      try FileManager.default.removeItem(at: dead)
      let report = await inspect(home)
      let next = try #require(report.checks.first { $0.id == "git.repos" }?.next)
      #expect(next.contains { $0.contains(dead.path) })
      #expect(!next.contains { $0.contains(healthy.path) })
      #expect(next.allSatisfy { $0.contains("init --scan <directory>") })
    }
  }

  @Test(arguments: ["2026-11-04T15:21:11.859Z", "2026-11-04T13:46:12.426Z"])
  func freshClaimWithCanonicalMillisecondsIsNotReported(claimedAt: String) async throws {
    try await withScratchDirectory { home in
      let (_, queue) = try seedClaim(home, excess: -1)
      try await queue.write {
        try $0.execute(sql: "UPDATE task SET claimed_at=?", arguments: [claimedAt])
      }
      let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
      let at = try format.parse(claimedAt).addingTimeInterval(29 * 60)
      let report = await inspect(home, at: at)
      #expect(report.checks.first { $0.id == "data.claims" }?.status == .pass)
    }
  }

  @Test func nonCanonicalClaimTimestampIsReported() async throws {
    try await withScratchDirectory { home in
      let (_, queue) = try seedClaim(home, excess: -1)
      let claimedAt = "2026-11-04T15:21:11.123+02:00"
      try await queue.write {
        try $0.execute(sql: "UPDATE task SET claimed_at=?", arguments: [claimedAt])
      }
      let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
      let at = try format.parse(claimedAt).addingTimeInterval(29 * 60)
      let report = await inspect(home, at: at)
      #expect(report.checks.first { $0.id == "data.claims" }?.status == .warning)
    }
  }

  @Test func freshFetchWithCanonicalMillisecondsIsNotReported() async throws {
    try await withScratchDirectory { home in
      let (_, queue) = try seedClaim(home, excess: -1)
      let fetchedAt = "2026-11-04T15:21:11.859Z"
      try await queue.write {
        try $0.execute(sql: "UPDATE repo_path SET fetched_at=?", arguments: [fetchedAt])
      }
      let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
      let at = try format.parse(fetchedAt).addingTimeInterval(29 * 60)
      let report = await inspect(home, at: at)
      #expect(report.checks.first { $0.id == "git.fetch" }?.status == .pass)
    }
  }

  private func seedClaim(_ home: URL, excess: Double) throws -> (URL, DatabaseQueue) {
    let store = StorageSchemaTests.store(home)
    try store.initialize()
    let repo = home.appending(path: "acme")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    // Linked worktrees use a file marker rather than a directory.
    try Data("gitdir: ../main/.git/worktrees/acme\n".utf8).write(to: repo.appending(path: ".git"))
    let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    let queue = try DatabaseQueue(path: store.path)
    try queue.write { db in
      try db.execute(
        sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
      try db.execute(sql: "INSERT INTO repo(uid,workspace_id,slug) VALUES('acme',1,'platform')")
      try db.execute(
        sql: "INSERT INTO repo_path(repo_id,path,fetched_at) VALUES(1,?,?)",
        arguments: [repo.path, now.addingTimeInterval(-86400 - excess).formatted(format)])
      try db.execute(
        sql: """
          INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref)
          VALUES('acme',1,'api','API',1,'main')
          """
      )
      try db.execute(
        sql: "INSERT INTO worktree_override VALUES(?,1,'human:acme')", arguments: [repo.path])
      try db.execute(
        sql: """
          INSERT INTO task(uid,workspace_id,seq,title,status,claimed_by,claimed_at,
            created_by,created_at,updated_at)
          VALUES('acme',1,1,'Acme private body','doing','agent:codex:acme',?,'human:acme','','')
          """,
        arguments: [now.addingTimeInterval(-7200 - excess).formatted(format)])
    }
    return (repo, queue)
  }

  @Test func lastWriteBackupCoverageUsesPublishedFiles() async throws {
    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      _ = try store.write { _ in () }
      #expect(await inspect(home).checks.first { $0.id == "data.backup" }?.status == .pass)
      #expect(
        await inspect(home, at: now.addingTimeInterval(86400 * 2)).checks.first {
          $0.id == "data.backup"
        }?.status == .pass)
      #expect(
        await inspect(home, at: now.addingTimeInterval(86400)).checks.first {
          $0.id == "data.backup"
        }?.status == .pass)
      let daily = home.appending(path: "backups/silta-2023-11-14.db")
      try FileManager.default.removeItem(at: daily)
      try FileManager.default.createSymbolicLink(
        at: daily, withDestinationURL: home.appending(path: "silta.db"))
      #expect(await inspect(home).checks.first { $0.id == "data.backup" }?.status == .warning)
    }
  }
}

extension DoctorServiceTests {
  @Test(arguments: [0, 1]) func walWarningStartsAboveSixtyFourMiB(excess: Int) throws {
    try withScratchDirectory { home in
      let url = home.appending(path: "silta.db-wal")
      #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }  // best-effort test file cleanup
      try handle.truncate(atOffset: UInt64(64 * 1024 * 1024 + excess))
      #expect(DoctorService.wal(home).status == (excess == 0 ? .pass : .warning))
    }
  }
}
