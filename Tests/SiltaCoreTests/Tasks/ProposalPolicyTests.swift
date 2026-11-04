import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ProposalPolicyTests {
  static func setup(
    _ home: URL, policy: String? = nil, clock: FakeClock = FakeClock(now: TaskServiceTests.now)
  ) throws -> SiltaEnvironment {
    let env = try TaskServiceTests.environment(home, clock: clock)
    try TaskServiceTests.setup(env)
    try set(policy, in: env.db)
    return env
  }

  static func set(_ policy: String?, in store: DatabaseStore) throws {
    try WorkspaceSettingsRegressionTests.set(
      policy.map { "{\"proposals\":\"\($0)\"}" } ?? "{}", in: store)
  }

  static func snapshot(_ env: SiltaEnvironment) throws -> [Int] {
    try env.db.read { db in
      let counts = try ["task", "task_event", "approval", "task_plan_rev", "change_log"].map {
        try #require(try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)"))
      }
      return counts + [
        try #require(try Int.fetchOne(db, sql: "SELECT coalesce(sum(next),0) FROM seq_counter"))
      ]
    }
  }

  @Test(
    arguments: ["absent", "triage", "ask"].flatMap { policy in [false, true].map { (policy, $0) } },
    ["plain", "start", "claimed", "unclaimed", "human"])
  func creationMatrix(choice: (String, Bool), mode: String) async throws {
    let (policy, approved) = choice
    try await withScratchDirectory { home in
      var env = try Self.setup(home, policy: policy == "absent" ? nil : policy)
      if mode == "human" {
        env = try TaskServiceTests.environment(home, actor: TaskServiceTests.human())
      }
      let service = TaskService(environment: env, approved: approved ? "Create Acme work" : nil)
      var draft = TaskDraft(title: "Acme work")
      draft.start = mode == "start"
      if policy == "ask", mode == "plain", !approved {
        draft.source = "note:Pwd=" + "acme-secret"
        draft.description = "Pwd=" + "acme-secret"
      }
      if ["claimed", "unclaimed"].contains(mode) {
        let parentEnv =
          mode == "claimed"
          ? env
          : try TaskServiceTests.environment(
            home, actor: .agent(tool: "codex", session: "other"))
        var parent = TaskDraft(title: "Acme parent")
        parent.start = true
        _ = try await TaskService(environment: parentEnv).add(parent, directory: home)
        draft.parent = "AC-1"
      }
      let ordinary =
        mode == "start" ? "doing" : ["claimed", "human"].contains(mode) ? "todo" : "proposed"
      let before = try Self.snapshot(env)
      if policy == "ask", ordinary == "proposed", !approved {
        do {
          _ = try await service.add(draft, directory: home)
          Issue.record("unapproved proposal accepted")
        } catch let error as ActorError {
          #expect(error.code == .humanOnly && error.message.contains("proposals: ask"))
          #expect(error.next[0].contains("silta --ws 'acme' task add"))
          #expect(!error.next.joined().contains("acme-secret"))
        }
        #expect(try Self.snapshot(env) == before)
      } else {
        let used = approved && ordinary == "proposed"
        let result = try await service.add(draft, directory: home)
        #expect(result.status == (used ? "todo" : ordinary))
        #expect(try Self.snapshot(env)[2] == (used ? 1 : 0))
      }
    }
  }

  struct ImportCase: Sendable {
    let policy: String
    let approved: Bool
    let split: Bool
    let preview: Bool
  }

  static let imports = ["triage", "ask"].flatMap { policy in
    [false, true].flatMap { approved in
      [false, true].flatMap { split in
        [false, true].map {
          ImportCase(policy: policy, approved: approved, split: split, preview: $0)
        }
      }
    }
  }

  @Test(arguments: imports, ["plain", "claimed", "unclaimed", "human"])
  func importAndPreview(choice: ImportCase, mode: String) async throws {
    let policy = choice.policy, approved = choice.approved
    let split = choice.split, preview = choice.preview
    try await withScratchDirectory { home in
      var env = try Self.setup(home, policy: policy)
      if mode == "human" {
        env = try TaskServiceTests.environment(home, actor: TaskServiceTests.human())
      }
      let service = TaskService(environment: env, approved: approved ? "Import Acme work" : nil)
      var options = TaskImport()
      options.split = split
      options.dryRun = preview
      if ["claimed", "unclaimed"].contains(mode) {
        let parentEnv =
          mode == "claimed"
          ? env
          : try TaskServiceTests.environment(
            home, actor: .agent(tool: "codex", session: "other"))
        var parent = TaskDraft(title: "Acme parent")
        parent.start = true
        _ = try await TaskService(environment: parentEnv).add(parent, directory: home)
        options.parent = "AC-1"
      }
      let ordinary = ["claimed", "human"].contains(mode) ? "todo" : "proposed"
      let before = try Self.snapshot(env)
      if policy == "ask", !approved, !preview, ordinary == "proposed" {
        await #expect(throws: ActorError.self) {
          _ = try await service.fromPlan(TaskImportTests.text, options: options, directory: home)
        }
        #expect(try Self.snapshot(env) == before)
      } else {
        let result = try await service.fromPlan(
          TaskImportTests.text, options: options, directory: home)
        let used = approved && !preview && ordinary == "proposed"
        let status = used ? "todo" : ordinary
        #expect(result.preview.status == status)
        #expect(result.preview.steps.allSatisfy { $0.status == (split ? status : nil) })
        if preview {
          #expect(result.tasks.isEmpty)
          #expect(try Self.snapshot(env) == before)
        } else {
          #expect(result.tasks.count == (split ? 3 : 1))
          #expect(result.tasks.allSatisfy { $0.status == status })
          #expect(try Self.snapshot(env)[2] == (used ? 1 : 0))
        }
      }
    }
  }

  @Test(arguments: ["triage", "ask"], ["add", "checklist", "split"])
  func combinedSecretConsentRecordsOnce(policy: String, operation: String) async throws {
    try await withScratchDirectory { home in
      let env = try Self.setup(home, policy: policy)
      let service = TaskService(environment: env, approved: "Keep Acme content")
      let secret = "Pwd=" + "acme-value"
      if operation == "add" {
        var draft = TaskDraft(title: "Acme work")
        draft.description = secret
        draft.allowSecret = true
        #expect(try await service.add(draft, directory: home).status == "todo")
      } else {
        var options = TaskImport()
        options.split = operation == "split"
        options.allowSecret = true
        let result = try await service.fromPlan(
          "# Acme\n\n\(secret)\n\n- First\n- Second\n", options: options, directory: home)
        #expect(result.tasks.allSatisfy { $0.status == "todo" })
      }
      #expect(try Self.snapshot(env)[2] == 1)
      let command = try env.db.read { try String.fetchOne($0, sql: "SELECT command FROM approval") }
      #expect(command?.contains(" -> AC-1") == true && command?.contains("acme-value") == false)
    }
  }

  @Test func splitFailureRollsBackRootAndApproval() async throws {
    try await withScratchDirectory { home in
      let env = try Self.setup(home, policy: "ask")
      try env.db.write {
        try $0.database.execute(
          sql: """
            CREATE TRIGGER fail_child BEFORE INSERT ON task WHEN NEW.title='Second'
            BEGIN SELECT RAISE(ABORT,'Acme child rejected'); END
            """)
      }
      let before = try Self.snapshot(env)
      var options = TaskImport()
      options.split = true
      await #expect(throws: StorageError.unavailable) {
        _ = try await TaskService(environment: env, approved: "Import Acme work").fromPlan(
          TaskImportTests.text, options: options, directory: home)
      }
      #expect(try Self.snapshot(env) == before)
    }
  }

  @Test(arguments: ["triage", "ask"], ["", "<unused>"])
  func invalidConsentCannotCreateRows(policy: String, words: String) async throws {
    try await withScratchDirectory { home in
      let env = try Self.setup(home, policy: policy)
      let before = try Self.snapshot(env)
      do {
        _ = try await TaskService(environment: env, approved: words).add(
          TaskDraft(title: "Acme work"), directory: home)
        Issue.record("invalid consent accepted")
      } catch let error as ActorError {
        #expect(error.code == .invalid)
      }
      #expect(try Self.snapshot(env) == before)
    }
  }

  @Test(arguments: [false, true])
  func importRechecksPolicyAfterSourceValidation(approved: Bool) async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let source = root.appending(path: "plan.md")
      try TaskImportTests.text.write(to: source, atomically: true, encoding: .utf8)
      let env = try Self.setup(home.appending(path: "db"), policy: "triage")
      let git = ScriptedGitRunner(script: PlanSourceTests.script(root)) { request in
        if request.arguments.contains("ls-files") { try Self.set("ask", in: env.db) }
      }
      let interleaved = try TaskServiceTests.environment(home.appending(path: "db"), git: git)
      let service = TaskService(
        environment: interleaved, approved: approved ? "Import Acme work" : nil)
      var options = TaskImport()
      options.delete = true
      let before = try Self.snapshot(env)
      if approved {
        #expect(
          try await service.fromPlan(
            TaskImportTests.text, options: options, source: source,
            directory: root
          ).tasks.first?.status == "todo")
        #expect(!FileManager.default.fileExists(atPath: source.path))
      } else {
        await #expect(throws: ActorError.self) {
          _ = try await service.fromPlan(
            TaskImportTests.text, options: options, source: source, directory: root)
        }
        #expect(try Self.snapshot(env) == before)
        #expect(FileManager.default.fileExists(atPath: source.path))
      }
    }
  }

  @Test func switchesRetainExistingProposalsAndTheirAge() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try Self.setup(home, clock: clock)
      let service = TaskService(environment: env)
      _ = try await service.add(TaskDraft(title: "Acme idea"), directory: home)
      let original = try service.show("AC-1")
      clock.advance(milliseconds: 14 * 86400 * 1000 + 1)
      for policy in ["ask", "triage", "ask"] {
        _ = try WorkspaceConfig.parse(
          WorkspaceConfigTests.minimal + "settings: {proposals: \(policy)}")
        try Self.set(policy, in: env.db)
        #expect(try service.show("AC-1").createdAt == original.createdAt)
        var filter = TaskFilter()
        filter.status = "proposed"
        #expect(try service.list(filter).map(\.ref) == ["AC-1"])
      }
    }
  }
}
