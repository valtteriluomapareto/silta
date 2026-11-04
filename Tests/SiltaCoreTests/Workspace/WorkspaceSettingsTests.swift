import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceSettingsTests {
  @Test(arguments: ["aks", "yes"])
  func proposalPolicyYamlExplainsWords(value: String) throws {
    do {
      _ = try WorkspaceConfig.parse(
        WorkspaceConfigTests.minimal + "settings: {proposals: \(value)}")
      Issue.record("invalid proposal policy accepted")
    } catch let error as WorkspaceError {
      #expect(error.code == .invalid)
      #expect(error.message.contains("proposals must be triage or ask"))
      #expect(error.message.contains("Ask the human"))
      #expect(error.message.contains(value == "aks" ? "did you mean ask" : "triage: proposals"))
    }
  }

  @Test(arguments: ["on", "off", "yes", "no", "true", "false", "ON", "OFF", "YES", "NO"])
  func booleanSettingsNameAcceptedWords(value: String) throws {
    do {
      _ = try WorkspaceConfig.parse(
        WorkspaceConfigTests.minimal + "settings: {review_gate: \(value)}")
      Issue.record("boolean setting accepted")
    } catch let error as WorkspaceError {
      #expect(error.code == .invalid)
      #expect(
        error.message == "line 2: " + WorkspaceSettingsRegressionTests.gloss
      )
    }
  }

  @Test(arguments: [("humna", "human"), ("None", "none")])
  func unknownWordsSuggestAValidValue(value: String, suggested: String) throws {
    do {
      _ = try WorkspaceConfig.parse(
        WorkspaceConfigTests.minimal + "settings: {review_gate: '\(value)'}")
      Issue.record("unknown setting accepted")
    } catch let error as WorkspaceError {
      #expect(
        error.message
          == "line 2: review_gate must be none, any or human; did you mean \(suggested)? "
          + "Ask the human which policy to use.")
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
    "{\"review_gate\":null}",
  ])
  func malformedGateValuesFailClosed(settings: String) async throws {
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
      await #expect(throws: WorkspaceError.self) {
        _ = try await service.close("AC-1", result: "Must not close.", directory: home)
      }
      #expect(try TaskOrganizationTests.counts(service) == before)
      #expect(
        try env.db.read { try String.fetchOne($0, sql: "SELECT status FROM task") } == "doing")
    }
  }
}
