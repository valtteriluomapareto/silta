import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskImportTests {
  static let text = "# Acme release\n\nContext\n\n- First\n  Nested detail\n- Second\n"

  @Test func parserPreservesContentAndIgnoresFencedAndNestedMarkers() throws {
    let source =
      "~~~md\n# Fake\n- Fake\n~~~\n# Åcme\n\nContext\n\n"
      + "1. [X] First\n  - Nested\n```\n- Code\n```\n2) Second"
    let parsed = try MarkdownPlan(source)
    #expect(parsed.title == "Åcme")
    #expect(parsed.steps.map(\.title) == ["First", "Second"])
    #expect(parsed.steps[0].description == "  - Nested\n```\n- Code\n```\n")
    #expect(parsed.description == "~~~md\n# Fake\n- Fake\n~~~\n\nContext\n\n")
    #expect(
      parsed.checklist
        == source.replacingOccurrences(of: "1. [X] First", with: "- [x] First")
        .replacingOccurrences(of: "2) Second", with: "- [ ] Second"))
    let headings = try MarkdownPlan("# Acme\r\nIntro\r\n## First\r\nBody\r\n## Second")
    #expect(headings.title == "Acme" && headings.steps.map(\.title) == ["First", "Second"])
    #expect(headings.steps[0].description == "Body\r\n")
    #expect(headings.checklist == "# Acme\r\nIntro\r\n- [ ] First\r\nBody\r\n- [ ] Second")
    for invalid in [
      "- No heading", "# No steps", "#   \n- Step", "# Acme\n- [ ] ",
      "```\n# Hidden\n- Hidden\n```",
    ] {
      #expect(throws: TaskError.self) { _ = try MarkdownPlan(invalid) }
    }
  }

  @Test func previewHasNoStorageAndEveryPathAppliesSecrets() async throws {
    try await withScratchDirectory { home in
      let secret = "Pwd=" + "acme-value"
      let source = "# \(secret)\n\n\(secret)\n\n- \(secret)\n  \(secret)\n"
      for split in [false, true] {
        let location = home.appending(path: split ? "split" : "checklist")
        let env = try TaskServiceTests.environment(location)
        var options = TaskImport()
        options.dryRun = true
        options.split = split
        let result = try await TaskService(environment: env).fromPlan(
          source, options: options, directory: home)
        #expect(result.dryRun && result.tasks.isEmpty)
        #expect(
          result.preview.status == "proposed"
            && result.preview.steps[0].status == (split ? "proposed" : nil))
        #expect(result.warnings == [SecretGuard.warning])
        let encoded = try JSONEncoder().encode(result)
        #expect(!(try #require(String(data: encoded, encoding: .utf8))).contains("acme-value"))
        #expect(!FileManager.default.fileExists(atPath: location.path))
        options.allowSecret = true
        let kept = try await TaskService(environment: env).fromPlan(
          source, options: options, directory: home)
        #expect(kept.preview.title == secret && kept.warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: location.path))
        try TaskServiceTests.setup(env)
        options.allowSecret = false
        options.dryRun = false
        let created = try await TaskService(environment: env).fromPlan(
          source, options: options, directory: home)
        #expect(created.tasks.count == (split ? 2 : 1))
        #expect(
          try env.db.read { try String.fetchAll($0, sql: "SELECT title FROM task") }.allSatisfy {
            !$0.contains("acme-value")
          })
        #expect(
          try env.db.read { try String.fetchAll($0, sql: "SELECT body_md FROM task_plan_rev") }
            .allSatisfy { !$0.contains("acme-value") })
        #expect(
          try env.db.read {
            try Int.fetchOne(
              $0, sql: "SELECT count(*) FROM task_event WHERE kind='secret_redacted'")
          } == (split ? 2 : 1))
      }
    }
  }

  @Test func humanPreviewRejectsSecretsAndPreservesImportRetryOptions() async throws {
    try await withScratchDirectory { home in
      let secret = "Pwd=" + "acme-value"
      let source = "# \(secret)\n\n- \(secret)\n"
      for split in [false, true] {
        let location = home.appending(path: split ? "split" : "checklist")
        var options = TaskImport()
        options.dryRun = true
        options.split = split
        let human = TaskService(
          environment: try TaskServiceTests.environment(location, actor: TaskServiceTests.human()))
        options.allowSecret = false
        do {
          _ = try await human.fromPlan(source, options: options, directory: home)
          Issue.record("Human secret preview accepted")
        } catch let error as SecretError {
          #expect(
            error.next == [
              "silta task from-plan <file>"
                + (split ? " --split" : "") + " --dry-run --allow-secret"
            ])
          #expect(!error.next.joined().contains("-F"))
        }
        options.allowSecret = true
        let allowed = try await human.fromPlan(source, options: options, directory: home)
        #expect(allowed.preview.title == secret && allowed.preview.status == "todo")
        #expect(!FileManager.default.fileExists(atPath: location.path))
      }
    }
  }

  @Test func checklistAndSplitUseOrdinaryCreationAndKeepSource() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      let source = home.appending(path: "plan.md")
      try Self.text.write(to: source, atomically: true, encoding: .utf8)
      let imported = try await service.fromPlan(Self.text, source: source, directory: home)
      #expect(imported.tasks.map(\.ref) == ["AC-1"])
      #expect(try service.show("AC-1").planRev == 1)
      #expect(
        try service.show("AC-1").plan
          == Self.text.replacingOccurrences(of: "- First", with: "- [ ] First")
          .replacingOccurrences(of: "- Second", with: "- [ ] Second"))
      var options = TaskImport()
      options.split = true
      let split = try await service.fromPlan(
        Self.text, options: options, source: source, directory: home)
      #expect(split.tasks.map(\.ref) == ["AC-2", "AC-3", "AC-4"])
      #expect(split.tasks.map(\.status) == ["proposed", "proposed", "proposed"])
      #expect(try service.show("AC-3").description == "  Nested detail\n")
      #expect(try service.show("AC-2").description == "Context\n\n")
      #expect(try service.show("AC-2").planRev == 0)
      #expect(
        try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task WHERE parent_id=2") }
          == 2)
      #expect(try String(contentsOf: source, encoding: .utf8) == Self.text)
      var root = TaskDraft(title: "Requested parent")
      root.start = true
      _ = try await service.add(root, directory: home)
      options.parent = "AC-5"
      #expect(
        try await service.fromPlan(Self.text, options: options, directory: home).tasks.map(\.status)
          == ["todo", "todo", "todo"])
      let humanEnv = try TaskServiceTests.environment(
        home.appending(path: "human"), actor: TaskServiceTests.human())
      try TaskServiceTests.setup(humanEnv)
      options.parent = nil
      #expect(
        try await TaskService(environment: humanEnv).fromPlan(
          Self.text, options: options, directory: home
        ).tasks.allSatisfy { $0.status == "todo" })
    }
  }
}

extension TaskImportTests {
  @Test func splitLimitAndInvalidDeleteNeverCreateStorage() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home.appending(path: "db"))
      let service = TaskService(environment: env)
      var options = TaskImport()
      options.split = true
      let eleven = "# Acme\n" + (1...11).map { "- Step \($0)\n" }.joined()
      await #expect(throws: TaskError.self) {
        _ = try await service.fromPlan(eleven, options: options, directory: home)
      }
      options.delete = true
      await #expect(throws: TaskError.self) {
        _ = try await service.fromPlan(Self.text, options: options, directory: home)
      }
      options.dryRun = true
      await #expect(throws: TaskError.self) {
        _ = try await service.fromPlan(
          Self.text, options: options, source: home.appending(path: "plan.md"), directory: home)
      }
      #expect(!FileManager.default.fileExists(atPath: env.home.url.path))
      try TaskServiceTests.setup(env)
      options.delete = false
      options.dryRun = false
      let ten = "# Acme\n" + (1...10).map { "- Step \($0)\n" }.joined()
      #expect(try await service.fromPlan(ten, options: options, directory: home).tasks.count == 11)
    }
  }

  @Test func laterChildCollisionRollsBackTheEntireImport() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let ids = SeededIDGenerator(seed: env.actor.description.utf8.reduce(0) { $0 + UInt64($1) })
      _ = try ids.next(at: TaskServiceTests.now)
      _ = try ids.next(at: TaskServiceTests.now)
      let duplicate = try ids.next(at: TaskServiceTests.now)
      try env.db.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
            VALUES(?,1,1,'Existing','todo',?,'t','t');
            INSERT INTO seq_counter(scope,next) VALUES('task:1',2)
            """, arguments: [duplicate, env.actor.description])
      }
      let source = home.appending(path: "plan.md")
      try Self.text.write(to: source, atomically: true, encoding: .utf8)
      var options = TaskImport()
      options.split = true
      await #expect(throws: StorageError.unavailable) {
        _ = try await TaskService(environment: env).fromPlan(
          Self.text, options: options, source: source, directory: home)
      }
      try env.db.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM task") == 1)
        for table in ["task_plan_rev", "task_event", "change_log"] {
          #expect(
            try Int.fetchOne(
              db,
              sql: "SELECT count(*) FROM \(table)"
                + (table == "change_log" ? " WHERE kind='task'" : "")) == 0)
        }
        #expect(try Int.fetchOne(db, sql: "SELECT next FROM seq_counter WHERE scope='task:1'") == 2)
      }
      #expect(try String(contentsOf: source, encoding: .utf8) == Self.text)
    }
  }
}

extension TaskImportTests {
  @Test func importHonorsRaisedWriterGateWithoutPartialRows() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      try env.db.write {
        try $0.database.execute(sql: "UPDATE meta SET value='4' WHERE key='min_writer_version'")
      }
      var options = TaskImport()
      options.split = true
      await #expect(throws: StorageError.schemaTooNew) {
        _ = try await TaskService(environment: env).fromPlan(
          Self.text, options: options, directory: home)
      }
      try env.db.read { (db: Database) throws in
        for table in ["task", "task_plan_rev", "task_event", "seq_counter"] {
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0)
        }
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM change_log WHERE kind='task'") == 0)
      }
    }
  }
}

extension TaskImportTests {
  @Test func fenceLengthKindAndClosingTextAreSignificant() throws {
    let source =
      "``\n````md\n```\n- Hidden\n~~~~\n- Hidden\n````text\n- Hidden\n````\n# Acme\n- Visible"
    #expect(try MarkdownPlan(source).steps.map(\.title) == ["Visible"])
    let mixed = "# Acme\n## Heading\nDetail\n- List\n"
    #expect(try MarkdownPlan(mixed).steps.map(\.title) == ["List"])
  }
}

extension TaskImportTests {
  @Test func importSecretRetryKeepsParentSplitAndDeleteWithoutSourceContent() async throws {
    try await withScratchDirectory { home in
      let human = TaskService(
        environment: try TaskServiceTests.environment(home, actor: TaskServiceTests.human()))
      var options = TaskImport()
      options.parent = "AC-7"
      options.split = true
      options.delete = true
      do {
        _ = try await human.fromPlan(
          "# Acme\n- Pwd=" + "acme-value", options: options,
          source: home.appending(path: "plan.md"), directory: home)
        Issue.record("Human secret import accepted")
      } catch let error as SecretError {
        #expect(
          error.next == [
            "silta task from-plan <file> --parent 'AC-7' --split --delete --allow-secret"
          ])
      }
      #expect(!FileManager.default.fileExists(atPath: home.appending(path: "silta.db").path))
    }
  }
}
