import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// A subtask takes its parent's app when `--app` is absent; an explicit app still wins.
@Suite(.timeLimit(.minutes(1)))
struct TaskParentAppTests {
  /// Two apps share the `platform` repository; `cli` lives in a second repository.
  static func configure(_ env: SiltaEnvironment, repo: URL, other: URL) throws {
    for path in [repo, other] {
      try FileManager.default.createDirectory(
        at: path.appending(path: ".git"), withIntermediateDirectories: true)
    }
    try WorkspaceConfigTests.apply(
      WorkspaceConfigTests.minimal + """
        repos: [{slug: platform}, {slug: tools}]
        apps:
          - {slug: api, repo: platform, ref: origin/main}
          - {slug: web, repo: platform, ref: origin/main, subpath: web}
          - {slug: cli, repo: tools, ref: origin/main}
        """, to: env.db)
    try WorkspaceSelection.use("acme", in: env.db)
    try env.db.write { transaction in
      try transaction.database.execute(
        sql: """
          INSERT INTO repo_path(repo_id,path)
          SELECT id,CASE slug WHEN 'platform' THEN ? ELSE ? END FROM repo
          """, arguments: [repo.path, other.path])
    }
  }

  static func identity(
    _ repository: URL, directory: URL
  ) -> (GitRequest, Result<GitResult, any Error>) {
    (
      .init(
        arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        directory: directory),
      .success(
        .init(
          termination: .exit(0),
          stdout: Data((repository.path + "/.git\n").utf8)))
    )
  }

  static func appTask(_ service: TaskService, directory: URL) async throws -> TaskResult {
    var draft = TaskDraft(title: "Acme app work")
    draft.app = "api"
    draft.start = true
    return try await service.add(draft, directory: directory)
  }

  @Test func subtaskInheritsTheParentAppAndRecordsItsCommit() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let other = home.appending(path: "other", directoryHint: .isDirectory)
      let git = ScriptedGitRunner(
        script: TaskGitTests.script(repo: repo, cwd: repo, completion: false)
          + TaskGitTests.script(repo: repo, cwd: repo, completion: true))
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: git)
      try Self.configure(env, repo: repo, other: other)
      let service = TaskService(environment: env)
      let root = try await Self.appTask(service, directory: repo)
      var child = TaskDraft(title: "Acme child")
      child.parent = root.ref
      let created = try await service.add(child, directory: repo)
      #expect(created.status == "todo")
      let shown = try service.show(created.ref)
      #expect(shown.app == "api" && shown.repoPath == repo.path && shown.parent == root.ref)
      let done = try await service.close(
        created.ref, result: "Done.", directory: repo
      ).result
      #expect(done.status == "done")
      let after = try service.show(created.ref)
      #expect(after.doneSHA == TaskGitTests.sha)
      #expect(git.isExhausted)
    }
  }

  @Test func explicitAppOverridesTheParentsApp() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let other = home.appending(path: "other", directoryHint: .isDirectory)
      let git = ScriptedGitRunner(script: [])
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: git)
      try Self.configure(env, repo: repo, other: other)
      let service = TaskService(environment: env)
      var parent = TaskDraft(title: "Acme parent")
      parent.app = "api"
      let root = try await service.add(parent, directory: home)
      var child = TaskDraft(title: "Acme child")
      child.parent = root.ref
      child.app = "web"
      let created = try await service.add(child, directory: home)
      #expect(try service.show(created.ref).app == "web")
      #expect(git.requests.isEmpty)
    }
  }

  /// A parent with no app keeps its subtask non-code, so completion still needs no commit.
  @Test func parentWithoutAnAppLeavesTheSubtaskWithoutOne() async throws {
    try await withScratchDirectory { home in
      let git = ScriptedGitRunner(script: [])
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: git)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      let root = try await service.add(TaskDraft(title: "Acme parent"), directory: home)
      var child = TaskDraft(title: "Acme child")
      child.parent = root.ref
      let created = try await service.add(child, directory: home)
      let shown = try service.show(created.ref)
      #expect(shown.app == nil && shown.repoPath == nil)
      #expect(git.requests.isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func fromPlanTakesTheParentsAppForEveryCreatedTask(split: Bool) async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let other = home.appending(path: "other", directoryHint: .isDirectory)
      let env = try TaskServiceTests.environment(home.appending(path: "db"))
      try Self.configure(env, repo: repo, other: other)
      let service = TaskService(environment: env)
      var parent = TaskDraft(title: "Acme parent")
      parent.app = "api"
      let root = try await service.add(parent, directory: home)
      var options = TaskImport()
      options.parent = root.ref
      options.split = split
      let imported = try await service.fromPlan(
        TaskImportTests.text, options: options, directory: home)
      #expect(!imported.tasks.isEmpty)
      for task in imported.tasks {
        #expect(try service.show(task.ref).app == "api")
        #expect(try service.show(task.ref).repoPath == repo.path)
      }
    }
  }

  @Test func startedSubtaskFromTheParentsRepositoryRecordsItsWorktree() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let other = home.appending(path: "other", directoryHint: .isDirectory)
      let git = ScriptedGitRunner(
        script: TaskGitTests.script(repo: repo, cwd: repo, completion: false)
          + TaskGitTests.script(repo: repo, cwd: repo, completion: false))
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: git)
      try Self.configure(env, repo: repo, other: other)
      let service = TaskService(environment: env)
      let root = try await Self.appTask(service, directory: repo)
      var child = TaskDraft(title: "Acme child")
      child.parent = root.ref
      child.start = true
      let created = try await service.add(child, directory: repo)
      #expect(created.status == "doing")
      let shown = try service.show(created.ref)
      #expect(shown.app == "api")
      #expect(shown.branch == "acme-release" && shown.worktree == repo.path)
      #expect(shown.claimedBy == TaskServiceTests.agent.description)
      #expect(git.isExhausted)
    }
  }

  @Test func startedSubtaskFromAnotherRepositoryIsRefused() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let other = home.appending(path: "other", directoryHint: .isDirectory)
      let git = ScriptedGitRunner(
        script: TaskGitTests.script(repo: repo, cwd: repo, completion: false)
          + [Self.identity(repo, directory: repo), Self.identity(other, directory: other)])
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: git)
      try Self.configure(env, repo: repo, other: other)
      let service = TaskService(environment: env)
      let root = try await Self.appTask(service, directory: repo)
      var child = TaskDraft(title: "Acme child")
      child.parent = root.ref
      child.start = true
      await #expect(throws: TaskError.foreignRepo) {
        _ = try await service.add(child, directory: other)
      }
      #expect(try service.list().map(\.ref) == [root.ref])
      #expect(git.isExhausted)
    }
  }

  /// The app the early read saw drives git and the recorded path, so a later change
  /// refuses instead of writing a stale repository binding.
  @Test func parentAppChangedBeforeTheInsertIsRefused() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let other = home.appending(path: "other", directoryHint: .isDirectory)
      let setup = try TaskServiceTests.environment(
        home.appending(path: "db"), actor: TaskServiceTests.human())
      try Self.configure(setup, repo: repo, other: other)
      var parent = TaskDraft(title: "Acme parent")
      parent.app = "api"
      let root = try await TaskService(environment: setup).add(parent, directory: home)
      let git = ScriptedGitRunner(
        script: TaskGitTests.script(repo: repo, cwd: repo, completion: false)
      ) { request in
        if request.arguments == ["rev-parse", "--abbrev-ref", "HEAD"] {
          try setup.db.write {
            try $0.database.execute(sql: "UPDATE task SET app_id=NULL WHERE seq=1")
          }
        }
      }
      let service = TaskService(
        environment: try TaskServiceTests.environment(home.appending(path: "db"), git: git))
      var child = TaskDraft(title: "Acme child")
      child.parent = root.ref
      child.start = true
      await #expect(throws: TaskError.changed(root.ref)) {
        _ = try await service.add(child, directory: repo)
      }
      #expect(try service.list().map(\.ref) == [root.ref])
      #expect(try service.show(root.ref).app == nil)
      #expect(git.isExhausted)
    }
  }

  /// `proposals: ask` refuses an inherited app's proposal exactly like an explicit one.
  @Test func proposalPolicyGatesAnInheritedAppTheSameWay() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let other = home.appending(path: "other", directoryHint: .isDirectory)
      let human = try TaskServiceTests.environment(
        home.appending(path: "db"), actor: TaskServiceTests.human())
      try Self.configure(human, repo: repo, other: other)
      try ProposalPolicyTests.set("ask", in: human.db)
      var parent = TaskDraft(title: "Acme parent")
      parent.app = "api"
      let root = try await TaskService(environment: human).add(parent, directory: home)
      let agent = TaskService(
        environment: try TaskServiceTests.environment(home.appending(path: "db")))
      var child = TaskDraft(title: "Acme child")
      child.parent = root.ref
      do {
        _ = try await agent.add(child, directory: home)
        Issue.record("unapproved inherited-app proposal accepted")
      } catch let error as ActorError {
        #expect(error.code == .humanOnly && error.message.contains("proposals: ask"))
        #expect(error.next[0].contains("silta --ws 'acme' task add"))
      }
      #expect(try agent.list().map(\.ref) == [root.ref])
    }
  }
}
