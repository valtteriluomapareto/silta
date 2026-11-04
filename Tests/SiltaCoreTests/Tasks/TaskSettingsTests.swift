import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskSettingsTests {
  @Test func policiesUseEachTasksWorkspaceAndCurrentSettings() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try TaskServiceTests.environment(home, clock: clock)
      try TaskServiceTests.setup(env)
      let config = try WorkspaceConfig.parse(
        "workspace: {slug: other, name: Acme Other, task_prefix: OT}\n"
          + "settings: {review_gate: human, archive_after_days: 0}")
      try env.db.write { try config.apply(in: $0, ids: env.ids, at: TaskServiceTests.now) }
      let acme = TaskService(environment: env)
      let other = TaskService(environment: env, workspace: "other")
      var draft = TaskDraft(title: "Scoped settings")
      draft.start = true
      _ = try await acme.add(draft, directory: home)
      _ = try await other.add(draft, directory: home)
      _ = try await acme.close("AC-1", result: "Finished.", directory: home)
      let before = try TaskOrganizationTests.counts(other)
      await #expect(throws: TaskError.gate("OT-1")) {
        _ = try await other.close("OT-1", result: "Must not close.", directory: home)
      }
      #expect(try TaskOrganizationTests.counts(other) == before)
      try WorkspaceConfigTests.apply(
        "workspace: {slug: other, name: Acme Other, task_prefix: OT}\n"
          + "settings: {review_gate: none, archive_after_days: 0}", to: env.db)
      _ = try await other.close("OT-1", result: "Finished.", directory: home)
      #expect(try !other.show("OT-1").archived)
      clock.advance(milliseconds: 1)
      let readCounts = try TaskOrganizationTests.counts(other)
      #expect(try other.show("OT-1").archived)
      #expect(try other.list().isEmpty)
      #expect(try !acme.show("AC-1").archived)
      #expect(try acme.list().map(\.ref) == ["AC-1"])
      #expect(try TaskOrganizationTests.counts(other) == readCounts)
      _ = try other.archive("OT-1", keep: true)
      #expect(try !other.show("OT-1").archived)
    }
  }

  @Test func completionRechecksSettingsAfterGitAndRollsBack() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let setup = try TaskServiceTests.environment(
        home.appending(path: "db"), actor: TaskServiceTests.human())
      try TaskGitTests.configure(setup, repo: repo)
      var draft = TaskDraft(title: "Acme gate race")
      draft.app = "api"
      _ = try await TaskService(environment: setup).add(draft, directory: repo)
      let git = ScriptedGitRunner(
        script: TaskGitTests.script(repo: repo, cwd: repo, completion: true)
      ) { request in
        if request.arguments == ["status", "--porcelain"] {
          try setup.db.write {
            try $0.database.execute(
              sql: "UPDATE workspace SET settings='{\"review_gate\":\"human\"}'")
          }
        }
      }
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: git)
      let service = TaskService(environment: env)
      let before = try TaskOrganizationTests.counts(service)
      await #expect(throws: TaskError.gate("AC-1")) {
        _ = try await service.close("AC-1", result: "Must not close.", directory: repo)
      }
      #expect(git.isExhausted)
      #expect(try TaskOrganizationTests.counts(service) == before)
      let after = try service.show("AC-1")
      #expect(after.status == "todo")
      #expect(after.result == nil)
      #expect(after.doneSHA == nil)
    }
  }
}
