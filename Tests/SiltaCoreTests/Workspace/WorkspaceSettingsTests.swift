import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceSettingsTests {
  @Test(arguments: ["on", "off", "yes", "no", "true", "false", "ON", "OFF", "YES", "NO"])
  func booleanSettingsNameAcceptedWords(value: String) throws {
    do {
      _ = try WorkspaceConfig.parse(
        WorkspaceConfigTests.minimal + "settings: {review_gate: \(value)}")
      Issue.record("boolean setting accepted")
    } catch let error as WorkspaceError {
      #expect(error.code == .invalid)
      #expect(
        error.message
          == "line 2: review_gate must be a word: none, any or human; "
          + "YAML booleans are not settings values"
      )
    }
  }

  @Test(arguments: [("humna", "human"), ("None", "none"), ("unknown", "none")])
  func unknownWordsSuggestAValidValue(value: String, suggested: String) throws {
    do {
      _ = try WorkspaceConfig.parse(
        WorkspaceConfigTests.minimal + "settings: {review_gate: '\(value)'}")
      Issue.record("unknown setting accepted")
    } catch let error as WorkspaceError {
      #expect(
        error.message
          == "line 2: review_gate must be none, any or human; did you mean \(suggested)?")
    }
  }

  @Test(arguments: ["{}", "{\"stale_days\":0}", "{\"future\":{\"enabled\":true}}"])
  func effectiveDefaultsNeverBecomeStoredKeys(settings: String) async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      try env.db.write {
        try $0.database.execute(sql: "UPDATE workspace SET settings=?", arguments: [settings])
      }
      var draft = TaskDraft(title: "Acme work")
      draft.start = true
      let service = TaskService(environment: env)
      _ = try await service.add(draft, directory: home)
      _ = try await service.close("AC-1", result: "Finished.", directory: home)
      #expect(try !service.show("AC-1").archived)
      try env.db.read { db in
        #expect(try String.fetchOne(db, sql: "SELECT settings FROM workspace") == settings)
        let rendered = try WorkspaceConfig.render(from: db, slug: "acme")
        let line = try #require(rendered.split(separator: "\n").first { $0.hasPrefix("settings:") })
        #expect(
          line
            == (settings.contains("stale_days") ? "settings: {\"stale_days\":0}" : "settings: {}"))
      }
    }
  }

  @Test(arguments: [
    "{\"review_gate\":\"robot\"}", "{\"review_gate\":false}",
    "{\"archive_after_days\":\"14\"}", "{\"stale_days\":\"90\"}",
    "{\"review_gate\":null}", "{\"archive_after_days\":null}", "{\"stale_days\":null}",
  ])
  func malformedKnownValuesFailClosed(settings: String) async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      var draft = TaskDraft(title: "Acme work")
      draft.start = true
      let service = TaskService(environment: env)
      _ = try await service.add(draft, directory: home)
      try env.db.write {
        try $0.database.execute(sql: "UPDATE workspace SET settings=?", arguments: [settings])
      }
      let before = try TaskOrganizationTests.counts(service)
      await #expect(throws: StorageError.unavailable) {
        _ = try await service.close("AC-1", result: "Must not close.", directory: home)
      }
      #expect(try TaskOrganizationTests.counts(service) == before)
      #expect(
        try env.db.read { try String.fetchOne($0, sql: "SELECT status FROM task") } == "doing")
    }
  }
}
