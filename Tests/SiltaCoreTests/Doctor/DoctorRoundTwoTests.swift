import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct DoctorRoundTwoTests {
  private let now = StorageSchemaTests.instant

  private func inspect(_ home: URL) async -> DoctorReport {
    await DoctorService.inspect(
      store: StorageSchemaTests.store(home), home: home,
      git: ScriptedGitRunner(script: [
        (
          GitRequest(arguments: ["--version"], directory: URL(filePath: "/")),
          .success(GitResult(termination: .exit(0), stdout: Data("git version 2.50\n".utf8)))
        )
      ]), at: now)
  }

  @Test(arguments: [false, true]) func initializationRequiresHumanAndNamesDatabase(empty: Bool)
    async throws
  {

    try await withScratchDirectory { home in
      let file = home.appending(path: "silta.db")
      if empty { try Data().write(to: file) }
      let report = await inspect(home)
      let check = try #require(report.checks.first { $0.next == ["silta init"] })
      #expect(check.nextBy == .human)
      #expect(check.message.contains(file.path))
      #expect(DoctorFailure(report: report).nextBy == .human)
      #expect(report.text.contains("ask human: silta init"))
    }

  }

  @Test func deadRepositoriesHaveCompleteBoundedRecoveryAndNoFetch() async throws {

    try await withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      let healthy = home.appending(path: "healthy")
      try FileManager.default.createDirectory(
        at: healthy.appending(path: ".git"), withIntermediateDirectories: true)
      try store.write { tx in
        try tx.database.execute(
          sql:
            "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
        for number in 1...7 {
          let slug = "gone-\(number)"
          try tx.database.execute(
            sql: "INSERT INTO repo(uid,workspace_id,slug) VALUES(?,1,?)", arguments: [slug, slug])
          try tx.database.execute(
            sql: "INSERT INTO repo_path(repo_id,path) VALUES(?,?)",
            arguments: [number, home.appending(path: slug).path])
        }
        try tx.database.execute(
          sql: "INSERT INTO repo(uid,workspace_id,slug) VALUES('healthy',1,'healthy')")
        try tx.database.execute(
          sql: "INSERT INTO repo_path(repo_id,path) VALUES(8,?)", arguments: [healthy.path])
      }
      let report = await inspect(home)
      let check = try #require(report.checks.first { $0.id == "git.repos" })
      #expect(check.status == .fail)
      #expect(check.nextBy == .human)
      #expect(check.next.count == 5)
      #expect(check.nextOmitted == 2)
      for (index, recipe) in check.next.enumerated() {
        #expect(recipe.contains(home.appending(path: "gone-\(index + 1)").path))
        #expect(recipe.contains("; silta --ws 'acme' init --scan <directory>"))
        #expect(!recipe.contains("&&"))
      }
      let fetch = try #require(report.checks.first { $0.id == "git.fetch" })
      #expect(fetch.next == ["silta --ws 'acme' repo fetch 'healthy'"])
      #expect(fetch.message.contains("1 missing"))
    }

  }

  @Test func absentBackupsDoNotSuggestRestorationOrUseCoverageJargon() async throws {

    try await withScratchDirectory { home in
      let report = await inspect(home)
      let check = try #require(report.checks.first { $0.id == "data.backup" })
      #expect(!check.message.contains("Restore"))
      #expect(!check.message.contains("write coverage"))
    }

  }

  @Test(arguments: ["missing", "empty", "initialized"]) func reportIDsMatchNamedOrder(state: String)
    async throws
  {
    try await withScratchDirectory { home in
      if state == "empty" { try Data().write(to: home.appending(path: "silta.db")) }
      if state == "initialized" { try StorageSchemaTests.store(home).initialize() }
      let ids = await inspect(home).checks.map(\.id)
      #expect(ids == DoctorService.checkOrder)
      #expect(Set(ids).count == ids.count)
    }
  }

  @Test func computedUnregisteredChecksRemainVisible() {
    let future = DoctorCheck(id: "install.future", status: .fail, message: "Acme diagnostic")
    let checks = DoctorService.orderedChecks([future])
    #expect(checks.map(\.id) == DoctorService.checkOrder + ["install.future"])
    #expect(checks.last?.status == .fail)
    #expect(checks.dropLast().allSatisfy { $0.status == .skipped })
  }

  @Test func realReadPathMapsSQLiteContentionToBusy() throws {
    try withScratchDirectory { home in
      do { try StorageSchemaTests.store(home).initialize() }
      let store = StorageSchemaTests.store(home)
      var configuration = Configuration()
      configuration.allowsUnsafeTransactions = true
      configuration.busyMode = .immediateError
      let blocker = try DatabaseQueue(path: store.path, configuration: configuration)
      try blocker.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=DELETE") }
      var reachedRead = false
      var acquiredLock = false
      var reachedQuery = false
      #expect(throws: StorageError.busy) {
        try store.read { db in
          reachedRead = true
          try db.execute(sql: "PRAGMA busy_timeout=0")
          try blocker.writeWithoutTransaction { try $0.execute(sql: "BEGIN EXCLUSIVE") }
          acquiredLock = true
          defer {
            do { try blocker.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") } } catch {
              Issue.record(error)
            }
          }
          reachedQuery = true
          _ = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
        }
      }
      #expect(reachedRead && acquiredLock && reachedQuery)
    }
  }
}
