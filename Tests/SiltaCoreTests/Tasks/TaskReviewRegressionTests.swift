import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskReviewRegressionTests {
  @Test(arguments: ["timeout", "signal", "spawn", "utf8"])
  func explicitSHAOperationalFailuresRemainEnvironmental(failure: String) async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "repo", directoryHint: .isDirectory)
      var script = TaskGitTests.script(repo: repo, cwd: repo, completion: true, override: "release")
      script[4].1 =
        switch failure {
        case "timeout": .success(.init(termination: .timedOut))
        case "signal": .success(.init(termination: .signal(9)))
        case "spawn": .failure(SeamError.gitUnavailable)
        default: .success(.init(termination: .exit(0), stdout: Data([255])))
        }
      script.removeLast()
      let git = ScriptedGitRunner(script: script)
      let env = try TaskServiceTests.environment(
        home.appending(path: "db"),
        actor: TaskServiceTests.human(), git: git)
      try TaskGitTests.configure(env, repo: repo)
      var draft = TaskDraft(title: "App")
      draft.app = "api"
      let service = TaskService(environment: env)
      _ = try await service.add(draft, directory: repo)
      var options = TaskCommit()
      options.sha = "release"
      await #expect(throws: TaskError.git) {
        _ = try await service.close("AC-1", result: "Done.", commit: options, directory: repo)
      }
      #expect(try service.show("AC-1").status == "todo")
      #expect(try service.show("AC-1").doneSHA == nil)
      #expect(git.isExhausted)
    }

  }

  @Test func missingRepositoryBindingIsEnvironmental() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try WorkspaceConfigTests.apply(
        WorkspaceConfigTests.minimal + """
          repos: [{slug: platform}]
          apps: [{slug: api, repo: platform, ref: origin/main}]
          """, to: env.db)
      try WorkspaceSelection.use("acme", in: env.db)
      var draft = TaskDraft(title: "App")
      draft.app = "api"
      draft.start = true
      do {
        _ = try await TaskService(environment: env).add(draft, directory: home)
        Issue.record("Missing binding accepted")
      } catch let error as any CodedError {
        #expect(error.code == .env)
      }
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 0)
    }

  }

  @Test func requiredLinkUIDCollisionRollsBackTaskCreation() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let ids = SeededIDGenerator(
        seed: TaskServiceTests.agent.description.utf8.reduce(0) { $0 + UInt64($1) })
      _ = try ids.next(at: TaskServiceTests.now)
      let linkUID = try ids.next(at: TaskServiceTests.now)
      try env.db.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
            VALUES('existing',1,1,'Acme task','todo',?,?,?);
            INSERT INTO seq_counter(scope,next) VALUES('task:1',2);
            """,
          arguments: [
            env.actor.description, TaskServiceTests.timestamp(TaskServiceTests.now),
            TaskServiceTests.timestamp(TaskServiceTests.now),
          ])
        let fields =
          "uid,workspace_id,from_kind,from_id,rel,to_kind,to_ext,created_by,created_at"
        try tx.database.execute(
          sql: """
            INSERT INTO link(\(fields))
            VALUES(?,1,'task',1,'source','note','acme.md',?,?)
            """,
          arguments: [
            linkUID, env.actor.description, TaskServiceTests.timestamp(TaskServiceTests.now),
          ])
      }
      var draft = TaskDraft(title: "New task")
      draft.topics = ["release"]
      do {
        _ = try await TaskService(environment: env).add(draft, directory: home)
        Issue.record("Expected a unique-constraint failure")
      } catch let error as StorageError {
        withKnownIssue("SI-30: unique constraints collapse into .unavailable") {
          #expect(error != .unavailable)
          #expect(
            error.message
              == "A write conflicted with existing data; this is likely a Silta bug. "
              + "Report the command you ran with the output of silta doctor.")
          #expect(error.next == ["silta doctor"])
          #expect(error.code == .env)
          #expect(error.code.exitCode == 9)
          #expect(error.code.nextBy == .human)
          let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
          let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
          for output in [text.stderr, json.stdout] {
            #expect(!output.contains("INSERT"))
            #expect(!output.contains("UNIQUE"))
            #expect(!output.contains(linkUID))
            #expect(!output.contains(env.actor.description))
          }
        }
      }
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 1)
      #expect(
        try env.db.read {
          try Int.fetchOne($0, sql: "SELECT next FROM seq_counter WHERE scope='task:1'")
        } == 2)
    }

  }
}
