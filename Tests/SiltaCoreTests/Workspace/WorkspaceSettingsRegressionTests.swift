import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceSettingsRegressionTests {
  static let gloss =
    "review_gate must be none, any or human. "
    + "none: no gate; any: done warns on a changes verdict; "
    + "human: done needs a human approve. Ask the human which policy to use."

  static func set(_ json: String, in store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(sql: "UPDATE workspace SET settings=?", arguments: [json])
    }
  }

  static func closed(_ home: URL) async throws -> TaskService {
    let env = try TaskServiceTests.environment(home)
    try TaskServiceTests.setup(env)
    let service = TaskService(environment: env)
    var draft = TaskDraft(title: "Acme work")
    draft.start = true
    _ = try await service.add(draft, directory: home)
    _ = try await service.close("AC-1", result: "Finished.", directory: home)
    return service
  }

  @Test(arguments: ["{\"review_gate\":\"robot\"}", "{\"stale_days\":\"90\"}"])
  func unrelatedSettingsDoNotBreakClosedReads(json: String) async throws {
    try await withScratchDirectory { home in
      let service = try await Self.closed(home)
      try Self.set(json, in: service.environment.db)
      let before = try TaskOrganizationTests.counts(service)
      #expect(try !service.show("AC-1").archived)
      #expect(try service.list().map(\.ref) == ["AC-1"])
      #expect(try TaskOrganizationTests.counts(service) == before)
    }
  }

  @Test(arguments: ["\"14\"", "1.5", "null", "-5"])
  func badArchiveValuesHaveConfigRecovery(value: String) async throws {
    try await withScratchDirectory { home in
      let service = try await Self.closed(home)
      try Self.set("{\"archive_after_days\":\(value)}", in: service.environment.db)
      let before = try TaskOrganizationTests.counts(service)
      for read in [{ _ = try service.show("AC-1") }, { _ = try service.list() }] {
        do {
          try read()
          Issue.record("invalid archive value accepted")
        } catch let error as any CodedError {
          #expect(error.code == .invalid)
          #expect(error.message.contains("acme"))
          #expect(error.message.contains("archive_after_days"))
          #expect(error.message.contains(value))
          #expect(error.next == ["silta --ws 'acme' ws show"])
        }
      }
      #expect(try TaskOrganizationTests.counts(service) == before)
    }
  }

  @Test func gateErrorIsActionableSafeAndWriteFree() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      var draft = TaskDraft(title: "Acme work")
      draft.start = true
      _ = try await service.add(draft, directory: home)
      let value = "Pwd=" + "acme-secret\n" + String(repeating: "x", count: 400)
      let json = try WorkspaceConfig.json(["review_gate": value])
      try Self.set(json, in: env.db)
      let before = try TaskOrganizationTests.counts(service)
      do {
        _ = try await service.close("AC-1", result: "Must not close.", directory: home)
        Issue.record("invalid gate accepted")
      } catch let error as any CodedError {
        #expect(error.code == .invalid)
        #expect(error.message.contains("acme"))
        #expect(error.message.contains("review_gate"))
        #expect(!error.message.contains("acme-secret"))
        #expect(!error.message.contains("\n"))
        #expect(error.message.unicodeScalars.count < 300)
        #expect(error.next == ["silta --ws 'acme' ws show"])
      }
      #expect(try TaskOrganizationTests.counts(service) == before)
    }
  }

  @Test func absentGateDoesNotWarnOnChanges() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      var draft = TaskDraft(title: "Acme work")
      draft.start = true
      _ = try await service.add(draft, directory: home)
      try env.db.write {
        try $0.database.execute(
          sql: """
            INSERT INTO comment(uid,task_id,seq,kind,verdict,body_md,actor,created_at)
            SELECT 'acme-review',id,1,'review','changes','Acme','agent:codex:other',created_at
            FROM task
            """)
      }
      let result = try await service.close("AC-1", result: "Finished.", directory: home)
      #expect(!result.result.warnings.contains { $0.code == "review_changes" })
    }
  }

  @Test func negativeStaleDaysAreRejected() throws {
    #expect(throws: WorkspaceError.self) {
      _ = try WorkspaceSettings(workspace: "acme", json: "{\"stale_days\":-5}").staleDays
    }
  }

  @Test(
    arguments: ["on", "off", "yes", "no", "true", "false", "y", "n", "ON", "Off"], [false, true])
  func booleanWordsRequireAnInformedChoice(word: String, quoted: Bool) throws {
    let value = quoted ? "'\(word)'" : word
    do {
      _ = try WorkspaceConfig.parse(
        WorkspaceConfigTests.minimal + "settings: {review_gate: \(value)}")
      Issue.record("boolean-like gate accepted")
    } catch let error as WorkspaceError {
      #expect(error.message == "line 2: " + Self.gloss)
      #expect(!error.message.contains("did you mean"))
    }
  }

  @Test(arguments: ["unknown", "review", "approve", "robot", "required"])
  func distantWordsHaveNoSuggestion(word: String) throws {
    do {
      _ = try WorkspaceConfig.parse(
        WorkspaceConfigTests.minimal + "settings: {review_gate: '\(word)'}")
      Issue.record("unknown gate accepted")
    } catch let error as WorkspaceError {
      #expect(error.message == "line 2: review_gate must be none, any or human")
    }
  }

  @Test(arguments: ["''", "1", "~", "[human]"])
  func nonWordsNameAcceptedPolicies(value: String) throws {
    do {
      _ = try WorkspaceConfig.parse(
        WorkspaceConfigTests.minimal + "settings: {review_gate: \(value)}")
      Issue.record("non-word gate accepted")
    } catch let error as WorkspaceError {
      #expect(error.message == "line 2: review_gate must be none, any or human")
    }
  }

  @Test(arguments: [false, true])
  func unchangedValidEditorInputWritesNothing(interactive: Bool) throws {
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      let yaml = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let before = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM change_log") }
      let identity = (SeededIDGenerator(seed: 3) as any IDGenerator, TaskServiceTests.now)
      let result: String?
      if interactive {
        result = try WorkspaceEditor.edit(
          slug: "acme", store: store, actor: TaskServiceTests.agent, identity: identity,
          approved: "Apply Acme settings", editor: { _ in 0 })
      } else {
        result = try WorkspaceEditor.apply(
          yaml, slug: "acme", store: store, actor: TaskServiceTests.agent, identity: identity,
          approved: "Apply Acme settings")
      }
      #expect(result == nil)
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM change_log") } == before)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }

  @Test(arguments: [false, true])
  func unchangedInvalidEditorInputIsValidated(interactive: Bool) throws {
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      try Self.set("{\"review_gate\":\"robot\"}", in: store)
      let yaml = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let human = try TaskServiceTests.human()
      let identity = (SeededIDGenerator(seed: 3) as any IDGenerator, TaskServiceTests.now)
      if interactive {
        var calls = 0
        _ = try WorkspaceEditor.edit(
          slug: "acme", store: store, actor: human, identity: identity
        ) { file in
          calls += 1
          if calls == 1 { return 0 }
          let content = try String(contentsOf: file, encoding: .utf8)
          #expect(content.hasPrefix("# line"))
          return 1
        }
        #expect(calls == 2)
      } else {
        #expect(throws: WorkspaceError.self) {
          _ = try WorkspaceEditor.apply(
            yaml, slug: "acme", store: store, actor: human, identity: identity)
        }
      }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
    }
  }
}
