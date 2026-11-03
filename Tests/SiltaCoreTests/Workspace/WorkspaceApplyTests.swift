import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceApplyTests {
  @Test(arguments: ["app", "topic"])
  func typedLinksPreventDeletionAndRollBackChanges(kind: String) throws {
    let yaml = WorkspaceConfigTests.minimal + """
      repos: [{slug: platform}]
      apps: [{slug: api, repo: platform, ref: origin/main}]
      topics: [{slug: messaging}]
      """
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      try WorkspaceConfigTests.apply(yaml, to: store)
      try store.write { tx in
        try tx.database.execute(sql: """
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
          SELECT 'acme-link',workspace_id,'task',1,'about',?,id,'human:acme','x'
          FROM \(kind)
          """, arguments: [kind])
      }
      do {
        try WorkspaceConfigTests.apply(
          WorkspaceConfigTests.minimal.replacingOccurrences(of: "name: Acme", with: "name: Changed"), to: store)
        Issue.record("referenced deletion accepted")
      } catch let error as WorkspaceError {
        #expect(error.code == .conflict)
      }
      let name = try store.read { try String.fetchOne($0, sql: "SELECT name FROM workspace") }
      #expect(name == "Acme")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(kind)") } == 1)
    }
  }

  @Test func retainedAppsCanExchangePrimaryRefs() throws {
    let base = WorkspaceConfigTests.minimal + "repos: [{slug: platform}]\n"
    let apps = "apps: [{slug: one, repo: platform, ref: origin/a}, {slug: two, repo: platform, ref: origin/b}]"
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      try WorkspaceConfigTests.apply(base + apps, to: store)
      let original = try store.read { try String.fetchAll($0, sql: "SELECT uid FROM app ORDER BY slug") }
      let swapped = apps.replacingOccurrences(of: "origin/a", with: "TEMP")
        .replacingOccurrences(of: "origin/b", with: "origin/a")
        .replacingOccurrences(of: "TEMP", with: "origin/b")
      try WorkspaceConfigTests.apply(base + swapped, to: store)
      let refs = try store.read { try String.fetchAll($0, sql: "SELECT ref FROM app ORDER BY slug") }
      #expect(refs == ["origin/b", "origin/a"])
      #expect(try store.read { try String.fetchAll($0, sql: "SELECT uid FROM app ORDER BY slug") } == original)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT sum(is_primary) FROM app") } == 2)
    }
  }

  @Test func retainedAliasesKeepNewerColumnsWhenMovedBetweenTopics() throws {
    try withKnownIssue("#9: retainedAliasesKeepNewerColumnsWhenMovedBetweenTopics") {
    let yaml = WorkspaceConfigTests.minimal
      + "topics: [{slug: one, aliases: [messages]}, {slug: two, aliases: []}]"
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      try WorkspaceConfigTests.apply(yaml, to: store)
      try store.write { tx in
        try tx.database.execute(sql: "ALTER TABLE topic_alias ADD COLUMN future TEXT")
        try tx.database.execute(sql: "UPDATE topic_alias SET future='kept'")
      }
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal
        + "topics: [{slug: one, aliases: []}, {slug: two, aliases: [messages]}]", to: store)
      let retained = try store.read { try String.fetchOne($0, sql: "SELECT future FROM topic_alias") }
      #expect(retained == "kept")
      let target = try store.read { try String.fetchOne($0, sql: """
        SELECT slug FROM topic
        JOIN topic_alias ON topic.id=topic_alias.topic_id
        """) }
      #expect(target == "two")
    }
    }
  }

  @Test(arguments: ["unsupported", "None"])
  func rejectsUnknownReviewGates(value: String) throws {
    try withKnownIssue("#9: rejectsUnknownReviewGates") {
    #expect(throws: WorkspaceError.self) {
      try WorkspaceConfig.parse(WorkspaceConfigTests.minimal + "settings: {review_gate: '\(value)'}")
    }
    }
  }

  @Test func editorRefusesRenameAndNonzeroExitCannotSaveChangedFile() throws {
    try withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      try WorkspaceSelection.use("acme", in: store)
      let human = try ActorID.detect(environment: ["USER": "acme"],
        terminal: .init(stdin: true, stdout: true), session: "acme")
      var calls = 0
      let result = try WorkspaceEditor.edit(slug: nil, store: store, actor: human,
        identity: (SeededIDGenerator(seed: 2), WorkspaceConfigTests.instant)) { file in
        calls += 1
        if calls == 1 {
          try WorkspaceConfigTests.minimal.replacingOccurrences(of: "slug: acme", with: "slug: other")
            .write(to: file, atomically: true, encoding: .utf8)
          return 0
        }
        #expect(try String(contentsOf: file, encoding: .utf8).contains("renaming is not supported"))
        try WorkspaceConfigTests.minimal.write(to: file, atomically: true, encoding: .utf8)
        return 1
      }
      #expect(result == nil)
      #expect(calls == 2)
      #expect(try WorkspaceSelection.list(in: store).map(\.slug) == ["acme"])
    }
  }
}
