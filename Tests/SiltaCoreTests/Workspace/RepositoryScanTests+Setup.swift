import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension RepositoryScanTests {
  @Test func generatedStubsUseValidSlugsAndSkipReservedNames() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "service")
      try FileManager.default.createDirectory(
        at: repo.appending(path: ".git"), withIntermediateDirectories: true)
      let refs = "origin/main\norigin/v1.2\norigin/v1.2-prod\norigin/v1/2\norigin/v1/2-prod\n"
      let git = ScriptedGitRunner(script: Self.script(try Self.path(repo), refs: refs))
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let outcome = try await RepositoryScan.scan(
        [repo], target: .named(slug: "acme", prefix: "AC"), store: store, git: git,
        identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      #expect(git.isExhausted)
      #expect(outcome.repositories == ["service"])
      #expect(outcome.apps == ["service-v1-2"])
      #expect(outcome.warnings.map(\.code) == ["scan_skipped_app", "scan_skipped_app"])
      #expect(outcome.warnings.contains { $0.message.contains("\"service\"") })
      #expect(outcome.warnings.contains { $0.message.contains("\"service-v1-2\"") })
      try store.read { (db: Database) throws in
        #expect(try String.fetchOne(db, sql: "SELECT ref FROM app") == "origin/v1.2")
        #expect(try String.fetchOne(db, sql: "SELECT prod_ref FROM app") == "origin/v1.2-prod")
      }
    }
  }
}
