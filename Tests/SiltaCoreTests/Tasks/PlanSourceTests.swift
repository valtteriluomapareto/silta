import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PlanSourceTests {
  static let locationArguments = [
    "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir",
  ]

  static func locationOutput(_ root: URL, admin: String = ".git") -> Data {
    let path = root.appending(path: admin).path
    return Data("\(root.path)\n\(path)\n\(path)\n".utf8)
  }

  static func script(_ root: URL, tracked: Bool = false) -> [(
    GitRequest, Result<GitResult, any Error>
  )] {
    let rootRequest = GitRequest(arguments: locationArguments, directory: root)
    let postRequest = GitRequest(
      arguments: locationArguments, directory: root.resolvingSymlinksInPath())
    let fileRequest = GitRequest(
      arguments: ["--literal-pathspecs", "ls-files", "--error-unmatch", "--", "plan.md"],
      directory: root.resolvingSymlinksInPath())
    let output = locationOutput(root)
    return [
      (rootRequest, .success(.init(termination: .exit(0), stdout: output))),
      (postRequest, .success(.init(termination: .exit(0), stdout: output))),
      (fileRequest, .success(.init(termination: .exit(tracked ? 0 : 1)))),
      (fileRequest, .success(.init(termination: .exit(1)))),
      (postRequest, .success(.init(termination: .exit(0), stdout: output))),
      (postRequest, .success(.init(termination: .exit(0), stdout: output))),
    ]
  }

  @Test(arguments: [
    "outside", "harness", "symlink", "directory", "changed", "tracked", "notgit", "gitfail",
    "rootutf8", "rootempty", "rootshape", "roottimeout", "rootsignal", "rootexit", "source_context",
  ])
  func unsafeSourcesNeverCreateOrDelete(mode: String) async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      var source = root.appending(path: "plan.md")
      var script = Self.script(root)
      if let failure = Self.rootFailure(mode, root: root) { script[0].1 = failure }
      if mode == "source_context" {
        script[1].1 = .success(
          .init(termination: .exit(0), stdout: Self.locationOutput(root, admin: "other")))
      }
      if mode == "tracked" { script[2].1 = .success(.init(termination: .exit(0))) }
      if mode == "outside" { source = home.appending(path: "plan.md") }
      if mode == "harness" {
        let harness = root.appending(path: ".claude/plans", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: harness, withIntermediateDirectories: true)
        source = harness.appending(path: "plan.md")
      }
      if mode == "directory" {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      } else if mode == "symlink" {
        let target = root.appending(path: "actual.md")
        try TaskImportTests.text.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
      } else {
        try (mode == "changed" ? "Changed" : TaskImportTests.text).write(
          to: source, atomically: true, encoding: .utf8)
      }
      let env = try TaskServiceTests.environment(
        home.appending(path: "db"), git: ScriptedGitRunner(script: script))
      try TaskServiceTests.setup(env)
      var options = TaskImport()
      options.delete = true
      do {
        _ = try await TaskService(environment: env).fromPlan(
          TaskImportTests.text, options: options, source: source, directory: root)
        Issue.record("Unsafe source accepted: \(mode)")
      } catch let error as TaskError {
        #expect(
          error.code
            == ([
              "gitfail", "rootutf8", "rootempty", "rootshape", "roottimeout", "rootsignal",
              "rootexit",
            ]
            .contains(mode) ? .env : .invalid))
      }
      #expect(FileManager.default.fileExists(atPath: source.path))
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 0)
    }
  }

  @Test(arguments: [
    "same", "changed", "replaced", "staged", "gitfail", "removed", "unwritable", "gitdir_changed",
    "source_gitdir_changed",
  ])
  func postcommitChangesPreserveSuccessAndAvoidRetry(mode: String) async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let source = root.appending(path: "plan.md")
      try TaskImportTests.text.write(to: source, atomically: true, encoding: .utf8)
      let db = DatabaseStore(
        home: home.appending(path: "db"), clock: FakeClock(now: TaskServiceTests.now), jitter: { 0 }
      )
      let runner = Self.postcommitRunner(mode, root: root, source: source, store: db)
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: runner)
      try TaskServiceTests.setup(env)
      var options = TaskImport()
      options.delete = true
      let result = try await TaskService(environment: env).fromPlan(
        TaskImportTests.text, options: options, source: source, directory: root)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
      #expect(result.tasks.map(\.ref) == ["AC-1"])
      #expect(result.warnings.map(\.code) == (mode == "same" ? [] : ["source_retained"]))
      #expect(runner.isExhausted)
      if mode == "staged" {
        let output = CommandOutput(text: "AC-1 proposed", data: result, warnings: result.warnings)
        Golden.forTests().check(
          OutputRouter.render(.success(output), mode: OutputMode(json: false)).stderr,
          "task-source-retained.txt")
      }
      if mode == "same" || mode == "removed" {
        #expect(!FileManager.default.fileExists(atPath: source.path))
      } else {
        #expect(
          try String(contentsOf: source, encoding: .utf8)
            == (mode == "changed" ? "Changed" : TaskImportTests.text))
      }
    }
  }
}

extension PlanSourceTests {
  @Test func precommitInterleavingAndLaterChildFailureRetainSource() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let source = root.appending(path: "plan.md")
      try TaskImportTests.text.write(to: source, atomically: true, encoding: .utf8)
      let steps = Self.script(root)
      let changing = ScriptedGitRunner(script: steps) { request in
        if request.arguments.contains("ls-files") {
          try Data("Changed".utf8).write(to: source)
        }
      }
      var options = TaskImport()
      options.delete = true
      let pre = try TaskServiceTests.environment(home.appending(path: "pre"), git: changing)
      try TaskServiceTests.setup(pre)
      await #expect(throws: TaskError.self) {
        _ = try await TaskService(environment: pre).fromPlan(
          TaskImportTests.text, options: options, source: source, directory: root)
      }
      #expect(try pre.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 0)
    }
  }

  @Test func laterChildFailurePreventsSourceDeletion() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let source = root.appending(path: "plan.md")
      try TaskImportTests.text.write(to: source, atomically: true, encoding: .utf8)
      let steps = Self.script(root)
      var options = TaskImport()
      options.delete = true
      let runner = ScriptedGitRunner(script: steps)
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: runner)
      try TaskServiceTests.setup(env)
      let ids = SeededIDGenerator(seed: env.actor.description.utf8.reduce(0) { $0 + UInt64($1) })
      _ = try ids.next(at: TaskServiceTests.now)
      _ = try ids.next(at: TaskServiceTests.now)
      let duplicate = try ids.next(at: TaskServiceTests.now)
      try env.db.write {
        try $0.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
            VALUES(?,1,1,'Existing','todo',?,'t','t');
            INSERT INTO seq_counter(scope,next) VALUES('task:1',2)
            """, arguments: [duplicate, env.actor.description])
      }
      options.split = true
      await #expect(throws: StorageError.unavailable) {
        _ = try await TaskService(environment: env).fromPlan(
          TaskImportTests.text, options: options, source: source, directory: root)
      }
      #expect(runner.requests.count == 3)
      #expect(try String(contentsOf: source, encoding: .utf8) == TaskImportTests.text)
      try env.db.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM task") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT next FROM seq_counter WHERE scope='task:1'") == 2)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM task_plan_rev") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM task_event") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM change_log WHERE kind='task'") == 0)
      }
    }
  }
}

extension PlanSourceTests {
  @Test func parentOwnershipIsRecheckedAfterFileValidation() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let source = root.appending(path: "plan.md")
      try TaskImportTests.text.write(to: source, atomically: true, encoding: .utf8)
      let db = DatabaseStore(
        home: home.appending(path: "db"), clock: FakeClock(now: TaskServiceTests.now), jitter: { 0 }
      )
      let steps = Self.script(root)
      let runner = ScriptedGitRunner(script: steps) { request in
        if request.arguments.first == "rev-parse" {
          try db.write {
            try $0.database.execute(sql: "UPDATE task SET claimed_by=NULL,claimed_at=NULL")
          }
        }
      }
      let env = try TaskServiceTests.environment(home.appending(path: "db"), git: runner)
      let service = try await TaskPlanTests.work(env, directory: root)
      try env.db.write {
        try $0.database.execute(sql: "ALTER TABLE task ADD COLUMN future TEXT DEFAULT 'default'")
        try $0.database.execute(sql: "UPDATE task SET future='retained'")
      }
      var options = TaskImport()
      options.parent = "AC-1"
      options.delete = true
      let result = try await service.fromPlan(
        TaskImportTests.text, options: options, source: source, directory: root)
      #expect(result.tasks.map(\.status) == ["proposed"])
      #expect(result.preview.status == "proposed")
      #expect(
        try env.db.read { try String.fetchOne($0, sql: "SELECT future FROM task WHERE seq=1") }
          == "retained")
    }
  }
}

extension PlanSourceTests {
  @Test(arguments: [false, true])
  func harnessProtectionCoversCanonicalAndLexicalDirectoryAliases(canonical: Bool) async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "repo", directoryHint: .isDirectory)
      let actual = root.appending(
        path: canonical ? ".claude" : "plans", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
      let alias = root.appending(path: canonical ? "plans" : ".claude", directoryHint: .isDirectory)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
      let source = alias.appending(path: "plan.md")
      try TaskImportTests.text.write(to: source, atomically: true, encoding: .utf8)
      let rootResult = GitResult(termination: .exit(0), stdout: Self.locationOutput(root))
      let script: [(GitRequest, Result<GitResult, any Error>)] = [
        (.init(arguments: Self.locationArguments, directory: root), .success(rootResult))
      ]
      let env = try TaskServiceTests.environment(
        home.appending(path: "db"), git: ScriptedGitRunner(script: script))
      try TaskServiceTests.setup(env)
      var options = TaskImport()
      options.delete = true
      do {
        _ = try await TaskService(environment: env).fromPlan(
          TaskImportTests.text, options: options, source: source, directory: root)
        Issue.record("Harness alias accepted")
      } catch let error as TaskError {
        #expect(error.code == .invalid)
      }
      #expect(FileManager.default.fileExists(atPath: source.path))
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 0)
    }
  }
}

extension PlanSourceTests {
  static func rootFailure(_ mode: String, root: URL) -> Result<GitResult, any Error>? {
    let rootFailures: [String: Result<GitResult, any Error>] = [
      "notgit": .success(.init(termination: .exit(128))),
      "gitfail": .failure(SeamError.gitUnavailable),
      "rootutf8": .success(.init(termination: .exit(0), stdout: Data([255]))),
      "rootempty": .success(.init(termination: .exit(0))),
      "rootshape": .success(
        .init(
          termination: .exit(0),
          stdout: Data((root.path + "\n" + root.appending(path: ".git").path).utf8))),
      "roottimeout": .success(.init(termination: .timedOut, stdout: Self.locationOutput(root))),
      "rootsignal": .success(.init(termination: .signal(9), stdout: Self.locationOutput(root))),
      "rootexit": .success(.init(termination: .exit(2), stdout: Self.locationOutput(root))),
    ]
    return rootFailures[mode]
  }

  static func postcommitRunner(_ mode: String, root: URL, source: URL, store: DatabaseStore)
    -> ScriptedGitRunner
  {
    var script = Self.script(root)
    let statuses: [String: GitTermination] = ["staged": .exit(0), "gitfail": .timedOut]
    if let status = statuses[mode] {
      script[3].1 = .success(.init(termination: status))
      script.removeLast(2)
    }
    let changed: [String: Int] = ["gitdir_changed": 4, "source_gitdir_changed": 5]
    if let index = changed[mode] {
      script[index].1 = .success(
        .init(termination: .exit(0), stdout: Self.locationOutput(root, admin: "other")))
      if index == 4 { script.removeLast() }
    }
    let calls = Mutex(0)
    let steps = script
    return ScriptedGitRunner(script: steps) { request in
      guard request.arguments.contains("ls-files") else { return }
      let count = calls.withLock {
        $0 += 1
        return $0
      }
      guard count == 2 else { return }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 1)
      switch mode {
      case "changed": try Data("Changed".utf8).write(to: source)
      case "replaced":
        try TaskImportTests.text.write(to: source, atomically: true, encoding: .utf8)
      case "removed": try FileManager.default.removeItem(at: source)
      case "unwritable":
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
      default: break
      }
    }
  }
}
