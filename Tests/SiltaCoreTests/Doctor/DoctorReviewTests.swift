import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct DoctorReviewTests {
  private let now = StorageSchemaTests.instant

  private func inspect(_ home: URL, at: Date? = nil) async -> DoctorReport {
    await DoctorService.inspect(
      store: StorageSchemaTests.store(home), home: home,
      git: ScriptedGitRunner(script: [
        (
          GitRequest(arguments: ["--version"], directory: URL(filePath: "/")),
          .success(GitResult(termination: .exit(0), stdout: Data("git version 2.50.0\n".utf8)))
        )
      ]), at: at ?? now)
  }

  @Test func unboundRepositoryWarnsWithoutSuggestingFetch() async throws {

    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC');
            INSERT INTO repo(uid,workspace_id,slug) VALUES('mobile',1,'mobile');
            """)
      }
      let report = await inspect(home)
      #expect(!report.checks.contains { $0.status == .fail })
      #expect(
        report.checks.contains {
          $0.status == .warning && $0.next.contains("silta --ws 'acme' init --scan <directory>")
        })
      #expect(report.checks.first { $0.id == "git.fetch" }?.status == .pass)
    }

  }

  @Test(arguments: [false, true]) func databaseFailureKeepsFileChecksAndBackupRecovery(
    missing: Bool
  ) async throws {

    try await withScratchDirectory { home in
      do {
        let store = StorageSchemaTests.store(home)
        try store.initialize()
        _ = try store.write { _ in () }
      }
      let file = home.appending(path: "silta.db")
      if missing {
        try FileManager.default.removeItem(at: file)
      } else {
        try Data("broken database".utf8).write(to: file)
      }
      let report = await inspect(home)
      let failure = try #require(report.checks.first { $0.id == "database.integrity" })
      #expect(failure.status == .fail)
      #expect(failure.next.first?.hasPrefix("/bin/ls -l ") == true)
      #expect(failure.message.contains("restore"))
      for id in ["database.wal", "data.backup"] {
        #expect(report.checks.first { $0.id == id }?.status != .skipped)
      }
      #expect(
        failure.next.filter { $0.contains("sqlite3") }.allSatisfy { $0.contains("-readonly") })
    }

  }

  @Test func checksPublishActionOwnersAndStableSkippedIDs() async throws {

    try await withScratchDirectory { home in
      let report = await inspect(home)
      let data = try JSONEncoder().encode(report)
      let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let checks = try #require(json["checks"] as? [[String: Any]])
      #expect(checks.allSatisfy { ["agent", "human"].contains($0["next_by"] as? String ?? "") })
      #expect(DoctorFailure(report: report).nextBy == .agent)
      #expect(report.text.contains("  next: silta init"))
      let ids = Set(report.checks.map(\.id))
      #expect(
        ids.isSuperset(of: [
          "install.path", "install.hook", "install.skill", "install.codex_root",
          "install.codex_marker", "index.integrity", "index.foreign_keys", "index.schema",
          "index.fts", "index.age",
        ]))
    }

  }

  @Test func freshAndIdleDatabasesHaveBackupCoverage() async throws {

    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      try FileManager.default.removeItem(at: home.appending(path: "backups"))
      #expect(await inspect(home).checks.first { $0.id == "data.backup" }?.status == .pass)
      _ = try store.write { _ in () }
      #expect(
        await inspect(home, at: now.addingTimeInterval(86400 * 10)).checks.first {
          $0.id == "data.backup"
        }?.status == .pass)
    }

  }

  @Test func emptyDatabaseSuggestsInitialization() async throws {

    try await withScratchDirectory { home in
      try Data().write(to: home.appending(path: "silta.db"))
      let report = await inspect(home)
      #expect(report.checks.first { $0.id == "database.schema" }?.next == ["silta init"])
    }

  }

  @Test func expiryAndLargeBacklogsAreConsistentAndBounded() async throws {

    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      let timestamp = now.addingTimeInterval(-7200).formatted(
        Date.ISO8601FormatStyle(includingFractionalSeconds: true))
      try store.write { tx in
        try tx.database.execute(
          sql:
            "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
        for number in 1...8 {
          try tx.database.execute(
            sql: """
              INSERT INTO task(uid,workspace_id,seq,title,status,claimed_by,claimed_at,
                created_by,created_at,updated_at)
              VALUES(?,1,?,'Acme','doing','agent:codex:acme',?,'human:acme','','')
              """, arguments: ["acme-\(number)", number, timestamp])
          try tx.database.execute(
            sql: "INSERT INTO repo(uid,workspace_id,slug) VALUES(?,1,?)",
            arguments: ["repo-\(number)", "repo-\(number)"])
          try tx.database.execute(
            sql: "INSERT INTO repo_path(repo_id,path) VALUES(?,?)",
            arguments: [number, home.appending(path: "repo-\(number)").path])
        }
      }
      let report = await inspect(home)
      let claim = try #require(report.checks.first { $0.id == "data.claims" })
      #expect(claim.status == .warning)
      #expect(claim.next.count <= 5)
      #expect(report.checks.first { $0.id == "git.repos" }?.next.count ?? 0 <= 5)
      #expect(report.text.contains("+3 more"))
      #expect(report.checks.first { $0.id == "git.fetch" }?.message.contains("8 missing") == true)
    }

  }

  @Test func permissionDenialIsNotCalledCorruption() async throws {

    try await withScratchDirectory { home in
      do { try StorageSchemaTests.store(home).initialize() }
      let path = home.appending(path: "silta.db").path
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
      defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
      }  // restore fixture access
      let report = await inspect(home)
      let check = try #require(report.checks.first { $0.id == "database.integrity" })
      #expect(check.message.contains("permission"))
      #expect(check.next.first?.hasPrefix("/bin/ls -l ") == true)
    }

  }

  @Test(arguments: ["empty", "future"]) func invalidBackupDoesNotCoverTheLastWrite(kind: String)
    async throws
  {
    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      _ = try store.write { _ in () }
      let daily = home.appending(path: "backups/silta-2023-11-14.db")
      if kind == "empty" {
        try Data().write(to: daily)
      } else {
        try FileManager.default.moveItem(
          at: daily, to: home.appending(path: "backups/silta-2099-01-01.db"))
      }
      #expect(await inspect(home).checks.first { $0.id == "data.backup" }?.status == .warning)
    }
  }

  @Test func busyReadReportsContentionRatherThanCorruption() {
    let check = DoctorService.readFailure(
      .busy, path: "/acme/silta.db", recovery: [], hasBackups: false)
    #expect(check.message.contains("busy"))
    #expect(!check.message.contains("corrupt"))
    #expect(check.next == ["/usr/sbin/lsof '/acme/silta.db'"])
    #expect(check.nextBy == .agent)
  }

  @Test func realBtreeCorruptionReturnsFailedIntegrityRows() async throws {
    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      let (page, pageSize) = try corruptiblePage(store.path)
      let file = URL(filePath: store.path)
      var bytes = try Data(contentsOf: file)
      let offset = (page - 1) * pageSize + 1
      bytes[offset] = 0
      bytes[offset + 1] = 1
      try bytes.write(to: file)
      let rows = try store.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") }
      #expect(rows != ["ok"])
      let report = await inspect(home)
      let check = try #require(report.checks.first { $0.id == "database.integrity" })
      #expect(check.status == .fail)
      #expect(check.message.contains("integrity check failed"))
      #expect(!check.next.isEmpty)
    }
  }

  private func corruptiblePage(_ path: String) throws -> (Int, Int) {
    let queue = try DatabaseQueue(path: path)
    try queue.write {
      try $0.execute(
        sql: "CREATE TABLE doctor_probe(value TEXT); INSERT INTO doctor_probe VALUES('Acme')")
    }
    let result = try queue.read { db in
      (
        try #require(
          try Int.fetchOne(
            db,
            sql: """
              SELECT rootpage FROM sqlite_master WHERE name='doctor_probe'
              """)),
        try #require(try Int.fetchOne(db, sql: "PRAGMA page_size"))
      )
    }
    try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
    try queue.close()
    return result
  }
}
