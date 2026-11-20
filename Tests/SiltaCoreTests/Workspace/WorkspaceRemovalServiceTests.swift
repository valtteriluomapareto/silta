import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct WorkspaceRemovalServiceTests {
  @Test(arguments: ["uid", "registration", "default"])
  func stateChangedDuringGitInspectionRefusesBeforeCreatingRecovery(change: String) async throws {
    try await withScratchDirectory { scratch in
      let home = scratch.appending(path: "data")
      let repo = scratch.appending(path: "not-a-clone")
      try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
      let setup = try TaskServiceTests.environment(home, actor: TaskServiceTests.human())
      try WorkspaceConfigTests.apply(
        WorkspaceConfigTests.minimal + "repos: [{slug: platform}]\n", to: setup.db)
      try setup.db.write { tx in
        try tx.database.execute(
          sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo", arguments: [repo.path])
      }
      let result = GitResult(
        termination: .exit(128), stdout: Data(),
        stderr: Data("fatal: not a git repository\n".utf8))
      let request = GitRequest(
        arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        directory: repo, lazyFetch: false)
      let git = ScriptedGitRunner(script: [(request, .success(result))]) { _ in
        try setup.db.write { tx in
          let sql =
            switch change {
            case "uid": "UPDATE workspace SET uid='replacement-acme'"
            case "registration": "UPDATE repo_path SET path='/acme/new-location'"
            default: "INSERT INTO meta(key,value) VALUES('current_workspace','acme')"
            }
          try tx.database.execute(sql: sql)
        }
      }
      let actor = try TaskServiceTests.environment(home, actor: TaskServiceTests.human(), git: git)
      do {
        _ = try await WorkspaceRemovalService(environment: actor).remove(
          "acme", dryRun: false, allowActive: false)
        Issue.record("Workspace removal accepted stale evidence.")
      } catch let error as WorkspaceRemovalError {
        #expect(error.code == .conflict)
        #expect(error.message.contains(change == "default" ? "saved default" : "changed"))
      }
      #expect(git.isExhausted)
      #expect(try WorkspaceSelection.resolve("acme", in: setup.db) == "acme")
      #expect(try Self.attempts(home).isEmpty)
    }
  }

  @Test func fixedTimeRemovalsHaveDistinctFreshSnapshots() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home, actor: TaskServiceTests.human())
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: env.db)
      try env.db.write { tx in
        let config = try WorkspaceConfig.parse(
          "workspace: {slug: beta, name: Beta, task_prefix: BE}")
        try config.apply(in: tx, ids: env.ids, at: env.clock.now())
      }
      let service = WorkspaceRemovalService(environment: env)
      let first = try await service.remove("acme", dryRun: false, allowActive: false)
      let second = try await service.remove("beta", dryRun: false, allowActive: false)
      let firstPath = try #require(first.backup)
      let secondPath = try #require(second.backup)
      #expect(firstPath != secondPath && first.recovery != second.recovery)
      #expect(try Self.workspaceSlugs(firstPath) == ["acme", "beta"])
      #expect(try Self.workspaceSlugs(secondPath) == ["beta"])
    }
  }

  @Test func backupPublicationFailureLeavesTheTargetInPlace() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home, actor: TaskServiceTests.human())
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: env.db)
      let backups = home.appending(path: "backups")
      let retained = home.appending(path: "retained")
      try FileManager.default.moveItem(at: backups, to: retained)
      try FileManager.default.createSymbolicLink(at: backups, withDestinationURL: retained)
      do {
        _ = try await WorkspaceRemovalService(environment: env).remove(
          "acme", dryRun: false, allowActive: false)
        Issue.record("Workspace removed without a publishable backup.")
      } catch let error as any CodedError {
        #expect(error.code == .env)
      }
      #expect(try WorkspaceSelection.resolve("acme", in: env.db) == "acme")
      #expect(try Self.attempts(home).isEmpty)
    }
  }

  private static func workspaceSlugs(_ path: String) throws -> [String] {
    var options = Configuration()
    options.readonly = true
    return try DatabaseQueue(path: path, configuration: options).read { db in
      try String.fetchAll(db, sql: "SELECT slug FROM workspace ORDER BY slug")
    }
  }

  private static func attempts(_ home: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: home.path).filter {
      $0.hasPrefix("removed-workspace-")
    }
  }
}
