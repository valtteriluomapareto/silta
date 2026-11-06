import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct AskAboutSettingsTests {
  @Test(arguments: ["standard", "short"])
  func explicitWordsRoundTripAndOmissionResets(_ word: String) throws {
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      let yaml = WorkspaceConfigTests.minimal + "settings: {ask_about: \(word)}\n"
      try WorkspaceConfigTests.apply(yaml, to: store)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE workspace SET settings=json_set(settings,'$.future',42)")
      }
      let rendered = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      #expect(rendered.contains("\"ask_about\":\"\(word)\""))
      try WorkspaceConfigTests.apply(rendered, to: store)
      #expect(try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") } == rendered)
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT settings FROM workspace") }
          == "{\"future\":42}")
    }
  }

  @Test(arguments: [
    "on", "off", "yes", "no", "true", "false", "ON", "'yes'", "shrot", "Short", "''", "null", "42",
    "[]", "{}",
  ])
  func invalidYamlNamesAcceptedWords(_ value: String) throws {
    do {
      _ = try WorkspaceConfig.parse(
        WorkspaceConfigTests.minimal + "settings: {ask_about: \(value)}\n")
      Issue.record("invalid ask_about accepted")
    } catch let error as WorkspaceError {
      #expect(error.code == .invalid)
      #expect(error.message.contains("ask_about must be standard or short"))
      if value == "shrot" { #expect(error.message.contains("did you mean short")) }
      if value == "on" {
        #expect(error.message.contains("standard:"))
        #expect(error.message.contains("short:"))
        #expect(error.message.contains("Ask the human"))
      }
    }
  }

  @Test(arguments: [#"{"ask_about":"short"}"#, #"{"ask_about":"future"}"#, #"{"ask_about":false}"#])
  func textPolicyDoesNotChangeTaskGates(_ json: String) async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      try TaskServiceTests.setup(env)
      try env.db.write {
        try $0.database.execute(sql: "UPDATE workspace SET settings=?", arguments: [json])
      }
      let service = TaskService(environment: env)
      let proposal = try await service.add(TaskDraft(title: "Acme idea"), directory: home)
      #expect(proposal.status == "proposed")
      var draft = TaskDraft(title: "Acme requested work")
      draft.start = true
      _ = try await service.add(draft, directory: home)
      _ = try await service.close("AC-2", result: "Acme finished", directory: home)
      #expect(try service.show("AC-2").status == "done")
      try env.db.write {
        try $0.database.execute(
          sql: "UPDATE workspace SET settings=json_set(settings,'$.proposals','ask')")
      }
      await #expect(throws: ActorError.self) {
        _ = try await service.add(TaskDraft(title: "Acme gated idea"), directory: home)
      }
    }
  }
}
