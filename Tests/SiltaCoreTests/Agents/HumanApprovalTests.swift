import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HumanApprovalTests {
  @Test(arguments: [
    "y", String(repeating: "a", count: 300), String(repeating: "e\u{301}", count: 150),
    "Use <the file> please",
  ])
  func trimsAndCountsUnicodeScalars(words: String) throws {
    let approval = try #require(
      try TaskServiceTests.agent.requireHuman(
        command: "silta ws edit -F <file>", approved: " \n" + words + "\t"))
    #expect(approval.words == words)
    #expect(approval.actor == TaskServiceTests.agent)
  }

  @Test(arguments: [
    "", " \n", "<placeholder>", "<Acme-private-words>", String(repeating: "a", count: 301),
    String(repeating: "e\u{301}", count: 151),
  ])
  func invalidWordsHaveNoEcho(words: String) throws {
    do {
      try TaskServiceTests.agent.requireHuman(command: "silta ws edit", approved: words)
      Issue.record("Invalid approval accepted")
    } catch let error as ActorError {
      #expect(error.code == .invalid && error.exitCode == 1)
      #expect(error.next == ["silta --help"])
      if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        #expect(!error.message.contains(words))
      }
    }
  }

  @Test func humansIgnoreWordsAndAgentWordsAreSecretGuarded() throws {
    let human = try TaskServiceTests.human()
    #expect(try human.requireHuman(command: "silta ws edit", approved: "<placeholder>") == nil)
    let secret = "Pwd=" + "acme-private-value"
    let approval = try #require(
      try TaskServiceTests.agent.requireHuman(
        command: "silta ws edit", approved: "Yes " + secret))
    #expect(!approval.words.contains("acme-private-value"))
    #expect(approval.words.contains("[REDACTED:"))
  }

  @Test func approvalAndMutationRollBackTogetherInBothDirections() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      var draft = TaskDraft(title: "Acme approved")
      draft.allowSecret = true
      let service = TaskService(environment: env, approved: "Create it.")
      try env.db.write { tx in
        try tx.database.execute(
          sql: """
            CREATE TRIGGER reject_approval BEFORE INSERT ON approval
            BEGIN SELECT RAISE(ABORT,'refuse'); END;
            """)
      }
      await #expect(throws: StorageError.self) { _ = try await service.add(draft, directory: home) }
      try env.db.read { (db: Database) throws in
        for table in ["approval", "task", "task_event", "seq_counter"] {
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0)
        }
      }
      try env.db.write { tx in
        try tx.database.execute(sql: "DROP TRIGGER reject_approval")
        try tx.database.execute(
          sql: """
            CREATE TRIGGER reject_approval_change BEFORE INSERT ON change_log
            WHEN NEW.kind='approval'
            BEGIN SELECT RAISE(ABORT,'refuse'); END;
            """)
      }
      await #expect(throws: StorageError.self) { _ = try await service.add(draft, directory: home) }
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 0)
      try env.db.write { try $0.database.execute(sql: "DROP TRIGGER reject_approval_change") }
      #expect(try await service.add(draft, directory: home).ref == "AC-1")
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
    }
  }

  @Test func everyExistingSecretOverrideRecordsOnceAndRetainsOnlyApprovedBodies() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env, approved: "Yes. Pwd=" + "acme-quote")
      let secret = "Pwd=" + "acme-body"
      var draft = TaskDraft(title: "Acme")
      draft.start = true
      draft.description = secret
      draft.allowSecret = true
      _ = try await service.add(draft, directory: home)
      _ = try service.plan("AC-1", text: "- [ ] " + secret, allowSecret: true)
      _ = try service.tick("AC-1", step: 1, done: true, allowSecret: true)
      var commit = TaskCommit()
      commit.allowSecret = true
      commit.force = true
      _ = try await service.close("AC-1", result: secret, commit: commit, directory: home)
      var options = TaskImport()
      options.allowSecret = true
      options.split = true
      _ = try await service.fromPlan(
        "# Acme import\n- One\n- Two", options: options, directory: home)
      commit.force = false
      _ = try await service.close(
        "AC-2", result: secret, dropped: true, commit: commit, directory: home)
      try env.db.read { (db: Database) throws in
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM approval ORDER BY id")
        try #require(rows.count == 6)
        #expect(Set(rows.compactMap { $0["uid"] as String? }).count == 6)
        #expect(rows.allSatisfy { ($0["words"] as String).contains("[REDACTED:") })
        #expect(rows.allSatisfy { ($0["actor"] as String) == TaskServiceTests.agent.description })
        #expect(rows.allSatisfy { ($0["workspace"] as String?) == "acme" })
        #expect(rows.allSatisfy { ($0["created_at"] as String) == "2023-11-14T22:13:20.000Z" })
        let commands = rows.map { $0["command"] as String }
        #expect(commands[0] == "silta task add --start --allow-secret -> AC-1")
        #expect(commands[2].contains("--step 1 --done --allow-secret"))
        #expect(commands[3].contains("--force --allow-secret"))
        #expect(commands[4] == "silta task from-plan --split --allow-secret -> AC-2 AC-3 AC-4")
        #expect(commands.allSatisfy { !$0.contains("acme-body") && !$0.contains("acme-quote") })
        #expect(try String.fetchOne(db, sql: "SELECT result_md FROM task WHERE seq=1") == secret)
        #expect(
          try String.fetchOne(db, sql: "SELECT plan_md FROM task WHERE seq=1") == "- [x] " + secret)
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM change_log WHERE kind='approval'") == 6)
      }
    }
  }

  @Test func refusalsCASWriterGateAndDryRunNeverStoreApprovals() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env, approved: "Proceed.")
      var draft = TaskDraft(title: "Acme")
      draft.start = true
      _ = try await service.add(draft, directory: home)
      _ = try service.plan("AC-1", text: "- [ ] Acme")
      #expect(throws: TaskError.staleRev("AC-1", actual: 1)) {
        _ = try service.plan("AC-1", text: "new", ifRevision: 0, allowSecret: true)
      }
      var options = TaskImport()
      options.allowSecret = true
      options.dryRun = true
      _ = try await service.fromPlan("# Acme\n- One", options: options, directory: home)
      let rival = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: "codex", session: "other")), approved: "Proceed.")
      #expect(throws: TaskError.self) { _ = try rival.plan("AC-1", text: "new", allowSecret: true) }
      await #expect(throws: TaskError.self) {
        _ = try await service.start("AC-99", steal: true, directory: home)
      }
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
      try env.db.write {
        try $0.database.execute(sql: "UPDATE meta SET value='4' WHERE key='min_writer_version'")
      }
      #expect(throws: StorageError.schemaTooNew) {
        _ = try service.plan("AC-1", text: "new", allowSecret: true)
      }
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }

  @Test func workspaceSaveUsesSameAtomicApprovalAndRowsOutliveWorkspace() throws {
    try withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let original = try env.db.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let updated = original.replacingOccurrences(of: "Acme", with: "Acme Changed")
      #expect(
        try WorkspaceEditor.apply(
          updated, slug: nil, store: env.db, actor: env.actor,
          identity: (env.ids, env.clock.now()), approved: "Apply this.") == "acme")
      #expect(
        try WorkspaceEditor.apply(
          updated, slug: nil, store: env.db, actor: env.actor,
          identity: (env.ids, env.clock.now()), approved: "Apply this.") == nil)
      try env.db.write { tx in
        try tx.database.execute(sql: "DELETE FROM topic")
        try tx.database.execute(sql: "DELETE FROM workspace")
      }
      #expect(
        try env.db.read { try String.fetchOne($0, sql: "SELECT workspace FROM approval") } == "acme"
      )
    }
  }
}

extension HumanApprovalTests {
  @Test func unusedWarningsIgnoreMalformedWordsAndHumanGatesNeverStoreRows() throws {
    let human = try TaskServiceTests.human()
    #expect(human.approvalWarnings("<placeholder>", used: true).map(\.code) == ["approval_unused"])
    #expect(
      TaskServiceTests.agent.approvalWarnings("", used: false).map(\.code) == ["approval_unused"])
    #expect(TaskServiceTests.agent.approvalWarnings(nil, used: true).isEmpty)
    #expect(TaskServiceTests.agent.approvalWarnings("Yes", used: true).isEmpty)
    #expect(
      TaskServiceTests.agent.approvalWarnings("Pwd=" + "acme-value", used: true).map(\.code)
        == ["secret_redacted"])
    try withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home, actor: human)
      try TaskServiceTests.setup(env)
      let initial = try env.db.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let changed = initial.replacingOccurrences(of: "Acme", with: "Acme Human")
      _ = try WorkspaceEditor.apply(
        changed, slug: nil, store: env.db, actor: human,
        identity: (env.ids, env.clock.now()), approved: "<placeholder>")
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }

  @Test func fileAndEditorValidationCancelAndAtomicityMatch() throws {
    try withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let initial = try env.db.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      for text in ["workspace: [", initial.replacingOccurrences(of: "acme", with: "other")] {
        #expect(throws: WorkspaceError.self) {
          _ = try WorkspaceEditor.apply(
            text, slug: "acme", store: env.db, actor: env.actor,
            identity: (env.ids, env.clock.now()), approved: "Apply.")
        }
      }
      for cancel in [true, false] {
        let result = try WorkspaceEditor.edit(
          slug: nil, store: env.db, actor: env.actor,
          identity: (env.ids, env.clock.now()), approved: "Edit."
        ) { file in
          if cancel {
            try initial.replacingOccurrences(of: "Acme", with: "Acme Cancelled")
              .write(to: file, atomically: true, encoding: .utf8)
          }
          return cancel ? 1 : 0
        }
        #expect(result == nil)
      }
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
      let changed = initial.replacingOccurrences(of: "Acme", with: "Acme Editor")
      _ = try WorkspaceEditor.edit(
        slug: nil, store: env.db, actor: env.actor,
        identity: (env.ids, env.clock.now()), approved: "Edit."
      ) { file in
        try changed.write(to: file, atomically: true, encoding: .utf8)
        return 0
      }
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
      try env.db.write { tx in
        try tx.database.execute(
          sql: """
            CREATE TRIGGER reject_approval BEFORE INSERT ON approval
            BEGIN SELECT RAISE(ABORT,'refuse'); END;
            """)
      }
      #expect(throws: StorageError.self) {
        _ = try WorkspaceEditor.apply(
          initial, slug: nil, store: env.db, actor: env.actor,
          identity: (env.ids, env.clock.now()), approved: "Revert.")
      }
      #expect(try env.db.read { try WorkspaceConfig.render(from: $0, slug: "acme") } == changed)
    }
  }
}

extension HumanApprovalTests {
  @Test(arguments: ["AC", "ZZ"])
  func workspaceFileRefusesRenameBeforeAnyInsert(prefix: String) throws {
    try withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let yaml = "workspace: {slug: other, name: Acme, task_prefix: " + prefix + "}"
      do {
        _ = try WorkspaceEditor.apply(
          yaml, slug: "acme", store: env.db, actor: env.actor,
          identity: (env.ids, env.clock.now()), approved: "Apply.")
        Issue.record("Workspace rename accepted")
      } catch let error as WorkspaceError {
        #expect(error.code == .invalid)
        #expect(error.message.contains("renaming is not supported"))
      }
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
      #expect(try WorkspaceSelection.list(in: env.db).map(\.slug) == ["acme"])
    }
  }
}
