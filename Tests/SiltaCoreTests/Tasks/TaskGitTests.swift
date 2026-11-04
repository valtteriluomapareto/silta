import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskGitTests {
  static let sha = String(repeating: "a", count: 40)

  static func script(
    repo: URL, cwd: URL, completion: Bool, dirty: Bool = false, override: String? = nil
  ) -> [(GitRequest, Result<GitResult, any Error>)] {
    var calls: [(GitRequest, String)] = [
      (
        .init(
          arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"], directory: repo),
        repo.path + "/.git"
      ),
      (
        .init(
          arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"], directory: cwd),
        repo.path + "/.git"
      ),
      (.init(arguments: ["rev-parse", "--show-toplevel"], directory: cwd), cwd.path),
      (.init(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], directory: cwd), "acme-release"),
    ]
    if completion {
      calls += [
        (
          .init(
            arguments: [
              "rev-parse", "--verify", "--quiet", "--end-of-options",
              (override ?? "HEAD") + "^{commit}",
            ], directory: cwd), sha
        ),
        (
          .init(arguments: ["status", "--porcelain"], directory: cwd), dirty ? " M app.swift\n" : ""
        ),
      ]
    }
    return calls.map { request, output in
      (request, .success(.init(termination: .exit(0), stdout: Data((output + "\n").utf8))))
    }
  }

  static func configure(_ env: SiltaEnvironment, repo: URL) throws {
    try FileManager.default.createDirectory(
      at: repo.appending(path: ".git"), withIntermediateDirectories: true)
    try WorkspaceConfigTests.apply(
      WorkspaceConfigTests.minimal + """
        repos: [{slug: platform}]
        apps: [{slug: api, repo: platform, ref: origin/main}]
        """, to: env.db)
    try WorkspaceSelection.use("acme", in: env.db)
    try env.db.write {
      try $0.database.execute(
        sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo",
        arguments: [repo.path])
    }
  }

  @Test func appRecordsWorktreeAndDirtyCompletionUsesStoredWorktree() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let work = home.appending(path: "worktree", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let git = ScriptedGitRunner(
        script: Self.script(repo: repo, cwd: work, completion: false)
          + Self.script(repo: repo, cwd: work, completion: true, dirty: true, override: "release"))
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: git)
      try Self.configure(env, repo: repo)
      var draft = TaskDraft(title: "App work")
      draft.app = "api"
      draft.start = true
      let service = TaskService(environment: env)
      _ = try await service.add(draft, directory: work)
      let before = try service.show("AC-1")
      #expect(
        before.branch == "acme-release" && before.worktree == work.path && before.app == "api")
      var options = TaskCommit()
      options.sha = "release"
      let result = try await service.close(
        "AC-1", result: "Done.", commit: options, directory: home
      ).result
      #expect(result.warnings.map(\.code) == ["dirty_worktree"])
      let after = try service.show("AC-1")
      #expect(
        after.doneSHA == Self.sha && after.doneBranch == "acme-release" && after.doneDirty == true)
      #expect(git.isExhausted)
    }
  }

  @Test func noAppAndNoSHAReallySkipGit() async throws {
    try await withScratchDirectory { home in
      let git = ScriptedGitRunner(script: [])
      let env = try TaskServiceTests.environment(
        home.appending(path: "db"), actor: TaskServiceTests.human(), git: git)
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      try Self.configure(env, repo: repo)
      var draft = TaskDraft(title: "Non-code")
      let service = TaskService(environment: env)
      _ = try await service.add(draft, directory: home)
      _ = try await service.start("AC-1", directory: home)
      _ = try await service.close("AC-1", result: nil, directory: home)
      #expect(try service.show("AC-1").doneSHA == nil)
      draft.app = "api"
      _ = try await service.add(draft, directory: home)
      var options = TaskCommit()
      options.noSHA = true
      _ = try await service.close("AC-2", result: nil, commit: options, directory: home)
      #expect(try service.show("AC-2").doneSHA == nil)
      #expect(git.requests.isEmpty)
    }
  }

  @Test func foreignRepoRefusesBeforeClaimAndInvalidSHARollsBack() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let cwd = home.appending(path: "other", directoryHint: .isDirectory)
      let args = ["rev-parse", "--path-format=absolute", "--git-common-dir"]
      let git = ScriptedGitRunner(script: [
        (
          .init(
            arguments: args, directory: repo
          ),
          .success(.init(termination: .exit(0), stdout: Data((repo.path + "/.git\n").utf8)))
        ),
        (
          .init(arguments: args, directory: cwd),
          .success(.init(termination: .exit(0), stdout: Data("/acme/foreign/.git\n".utf8)))
        ),
      ])
      let env = try TaskServiceTests.environment(
        home.appending(path: "db"), actor: TaskServiceTests.human(), git: git)
      try Self.configure(env, repo: repo)
      var draft = TaskDraft(title: "App")
      draft.app = "api"
      let service = TaskService(environment: env)
      _ = try await service.add(draft, directory: home)
      await #expect(throws: TaskError.foreignRepo) {
        _ = try await service.start("AC-1", directory: cwd)
      }
      #expect(try service.show("AC-1").status == "todo")
      #expect(try service.show("AC-1").claimedBy == nil)
      #expect(git.isExhausted)
      var script = Self.script(repo: repo, cwd: repo, completion: true, override: "foreign")
      script[4].1 = .success(.init(termination: .exit(1)))
      script.removeLast()
      let failing = ScriptedGitRunner(script: script)
      let same = TaskService(
        environment: try TaskServiceTests.environment(
          home.appending(path: "db"),
          actor: TaskServiceTests.human(), git: failing))
      var options = TaskCommit()
      options.sha = "foreign"
      await #expect(throws: TaskError.foreignRepo) {
        _ = try await same.close(
          "AC-1", result: "Should roll back.", commit: options, directory: repo)
      }
      #expect(try service.show("AC-1").result == nil)
      #expect(failing.isExhausted)
    }
  }

  @Test(arguments: [GitTermination.exit(128), .signal(9), .timedOut])
  func gitFailuresAreCodedAndNeverCreateTasks(termination: GitTermination) async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let git = ScriptedGitRunner(script: [
        (
          .init(
            arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"], directory: repo
          ),
          .success(.init(termination: termination, stderr: Data("private diagnostic".utf8)))
        )
      ])
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: git)
      try Self.configure(env, repo: repo)
      var draft = TaskDraft(title: "App")
      draft.app = "api"
      draft.start = true
      await #expect(throws: TaskError.git) {
        _ = try await TaskService(environment: env).add(draft, directory: repo)
      }
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 0)
    }
  }
}

extension TaskGitTests {
  @Test func invalidUTF8CommitShapeAndMissingMarkerAreRefused() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: repo.appending(path: ".git"), withIntermediateDirectories: true)
      for index in [0, 4] {
        var script = Self.script(repo: repo, cwd: repo, completion: true)
        script[index].1 = .success(
          .init(termination: .exit(0), stdout: index == 0 ? Data([255]) : Data("not-a-sha\n".utf8)))
        let git = ScriptedGitRunner(script: script)
        await #expect(throws: TaskError.git) {
          _ = try await TaskGit.inspect(
            repo: repo.path, directory: repo, runner: git, enabled: true, completion: true)
        }
        #expect(git.requests.count == index + 1)
      }
      try FileManager.default.removeItem(at: repo.appending(path: ".git"))
      let none = ScriptedGitRunner(script: [])
      for path in [nil, repo.path] as [String?] {
        await #expect(throws: TaskError.repository) {
          _ = try await TaskGit.inspect(
            repo: path, directory: repo, runner: none, enabled: true, completion: false)
        }
      }
      #expect(none.requests.isEmpty)
    }
  }
}

extension TaskGitTests {
  @Test(arguments: ["repository", "claim", "status"], [false, true])
  func mutableStateIsRecheckedAfterGit(change: String, completion: Bool) async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let human = try TaskServiceTests.environment(
        home.appending(path: "db"), actor: TaskServiceTests.human())
      try Self.configure(human, repo: repo)
      var draft = TaskDraft(title: "App race")
      draft.app = "api"
      _ = try await TaskService(environment: human).add(draft, directory: repo)
      let rival = ActorID.agent(tool: "codex", session: "rival")
      let steps = Self.script(repo: repo, cwd: repo, completion: completion)
      let git = ScriptedGitRunner(script: steps) { request in
        if request.arguments
          == (completion ? ["status", "--porcelain"] : ["rev-parse", "--abbrev-ref", "HEAD"])
        {
          try human.db.write {
            if change == "status" {
              try $0.database.execute(sql: "UPDATE task SET status='done' WHERE seq=1")
            } else if change == "repository" {
              try $0.database.execute(sql: "UPDATE task SET app_id=NULL WHERE seq=1")
            } else {
              try $0.database.execute(
                sql: "UPDATE task SET status='doing',claimed_by=?,claimed_at=? WHERE seq=1",
                arguments: [rival.description, TaskServiceTests.timestamp(TaskServiceTests.now)])
            }
          }
        }
      }
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: git)
      let expected: TaskError =
        switch change {
        case "repository": .changed("AC-1")
        case "status": .transition("AC-1", status: "done")
        default: .claimed("AC-1", holder: rival.description, minutes: 0, human: false)
        }
      let service = TaskService(environment: env)
      await #expect(throws: expected) {
        if completion {
          _ = try await service.close("AC-1", result: "Done.", directory: repo)
        } else {
          _ = try await service.start("AC-1", directory: repo)
        }
      }
      #expect(git.isExhausted)
      let after = try TaskService(environment: human).show("AC-1")
      #expect(after.claimedBy == (change == "claim" ? rival.description : nil))
    }
  }
}

extension TaskGitTests {
  @Test func newTaskRepositoryBindingIsRecheckedBeforeInsert() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      let setup = try TaskServiceTests.environment(home.appending(path: "db"))
      try Self.configure(setup, repo: repo)
      let steps = Self.script(repo: repo, cwd: repo, completion: false)
      let git = ScriptedGitRunner(script: steps) { request in
        if request.arguments == ["rev-parse", "--abbrev-ref", "HEAD"] {
          try setup.db.write {
            try $0.database.execute(sql: "UPDATE repo_path SET path='/acme/moved'")
          }
        }
      }
      let service = TaskService(
        environment: try TaskServiceTests.environment(home.appending(path: "db"), git: git))
      var draft = TaskDraft(title: "App race")
      draft.app = "api"
      draft.start = true
      await #expect(throws: TaskError.changed(nil)) {
        _ = try await service.add(draft, directory: repo)
      }
      #expect(try service.list().isEmpty)
      #expect(git.isExhausted)
    }
  }
}
