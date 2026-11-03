import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceConfigTests {
  static let minimal = "workspace: {slug: acme, name: Acme, task_prefix: AC}\n"

  static func store(_ home: URL) -> DatabaseStore {
    DatabaseStore(home: home, clock: FakeClock(now: instant), jitter: { 0 })
  }

  static var instant: Date {
    Date(timeIntervalSince1970: 1_700_000_000)
  }

  static func apply(_ text: String, to store: DatabaseStore) throws {
    let config = try WorkspaceConfig.parse(text)
    try store.write { try config.apply(in: $0, ids: SeededIDGenerator(seed: 1), at: instant) }
  }

  @Test func appendixARoundTripsEverySection() throws {
    let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let spec = try String(contentsOf: repo.appending(path: "docs/spec.md"), encoding: .utf8)
    let appendix = try #require(spec.components(separatedBy: "```yaml\n").last)
      .components(separatedBy: "```")[0]
    try withScratchDirectory { home in
      let store = Self.store(home)
      try Self.apply(appendix, to: store)
      let rendered = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      Golden.forTests().check(rendered, "workspace.yaml")
      try Self.apply(rendered, to: store)
      #expect(try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") } == rendered)
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='change_seq'")
        } == "2")
      #expect(
        try store.read { try String.fetchAll($0, sql: "SELECT kind FROM change_log ORDER BY seq") }
          == ["workspace", "workspace"])
      for (table, count) in [
        "repo": 4, "app": 7, "environment": 2, "service": 7,
        "edge": 5, "topic": 4, "topic_alias": 7, "source": 1,
      ] {
        #expect(
          try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") } == count)
      }
    }
  }

  @Test func diagnosticsCollectLinesSuggestionsAndConstraints() throws {
    let text =
      Self.minimal + """
        reops: []
        repos: [{slug: platform}, {slug: platform}]
        apps:
          - {slug: api, repo: platfrm, ref: origin/main, lifecycle: retired, extra: x}
          - {slug: one, repo: platform, ref: origin/main}
          - {slug: two, repo: platform, ref: origin/main}
        environments: [{app: ap, name: prod}, {app: ap, name: prod}]
        services: [crm, crm]
        edges: [{from: api, to: service:cr, kind: sdk, summary: test}]
        topics: [{slug: first, aliases: [MESSAGES]}, {slug: second, aliases: [messages]}]
        sources: [{kind: notes, root: x, include: wrong}, {kind: notes, root: x, include: []}]
        """
    do {
      _ = try WorkspaceConfig.parse(text)
      Issue.record("invalid configuration accepted")
    } catch let error as WorkspaceError {
      #expect(error.code == .invalid)
      for expected in [
        "line 2", "did you mean repos", "did you mean platform", "extra",
        "lifecycle", "primary", "duplicate", "messages", "include",
        "did you mean api", "did you mean crm",
      ] {
        #expect(error.message.contains(expected), "missing diagnostic: \(expected)")
      }
    }
  }

  @Test(arguments: [
    "workspace: []", "[]", "workspace: {slug: acme}", "apps: wrong",
    "workspace: {slug: acme, name: Acme, task_prefix: AC, name: Duplicate}",
    "workspace: {slug: acme, name: Acme, task_prefix: AC}\nsettings: {stale_days: -1}",
  ])
  func rejectsMalformedAndIncompleteDocuments(text: String) {
    #expect(throws: WorkspaceError.self) { _ = try WorkspaceConfig.parse(text) }
  }

  @Test func retainedRowsKeepUnknownColumnsAndJSONAndLocalPaths() throws {
    let yaml =
      Self.minimal + """
        repos: [{slug: platform}]
        apps: [{slug: api, repo: platform, ref: origin/main}]
        environments: [{app: api, name: prod, url: https://acme.example}]
        services: [crm]
        edges: [{from: api, to: service:crm, kind: sdk, summary: Acme}]
        topics: [{slug: messaging, aliases: [Messages, "e\u{301}"]}]
        sources: [{kind: notes, root: ~/notes, include: ['*.md']}]
        """
    try withScratchDirectory { home in
      let store = Self.store(home)
      try Self.apply(yaml, to: store)
      let tables = [
        "workspace", "repo", "app", "environment", "service", "edge", "topic", "source",
      ]
      let original = try store.read { db in
        try tables.map { try String.fetchOne(db, sql: "SELECT uid FROM \($0)") }
      }
      try store.write { tx in
        for table in tables {
          try tx.database.execute(sql: "ALTER TABLE \(table) ADD COLUMN future TEXT")
          try tx.database.execute(sql: "UPDATE \(table) SET future='kept'")
        }
        try tx.database.execute(
          sql: "UPDATE workspace SET settings='{\"future\":42,\"archive_after_days\":14}'")
        try tx.database.execute(
          sql: "INSERT INTO repo_path(repo_id,path) SELECT id,'/acme' FROM repo")
      }
      try Self.apply(
        yaml.replacingOccurrences(of: "https://acme.example", with: "https://new.acme.example"),
        to: store)
      try store.read { (db: Database) throws in
        #expect(
          try tables.map { try String.fetchOne(db, sql: "SELECT uid FROM \($0)") } == original)
        for table in tables {
          #expect(try String.fetchOne(db, sql: "SELECT future FROM \(table)") == "kept")
        }
        #expect(try String.fetchOne(db, sql: "SELECT settings FROM workspace") == "{\"future\":42}")
        #expect(try String.fetchOne(db, sql: "SELECT path FROM repo_path") == "/acme")
        let aliases = try String.fetchAll(db, sql: "SELECT alias FROM topic_alias ORDER BY alias")
        #expect(aliases.first == "messages")
        #expect(Array(try #require(aliases.last).utf8) == [195, 169])
      }
      try store.write {
        try $0.database.execute(sql: "UPDATE meta SET value='4' WHERE key='min_writer_version'")
      }
      #expect(throws: StorageError.schemaTooNew) { try Self.apply(Self.minimal, to: store) }
    }
  }

  @Test func referencedDeletionConflictsAndRollsBackButUnreferencedRowsDelete() throws {
    let yaml =
      Self.minimal
      + "repos: [{slug: platform}]\napps: [{slug: api, repo: platform, ref: origin/main}]\n"
    try withScratchDirectory { home in
      let store = Self.store(home)
      try Self.apply(yaml, to: store)
      let columns = "uid,workspace_id,seq,title,status,app_id,created_by,created_at,updated_at"
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO task(\(columns))
            SELECT 'acme-task',workspace_id,1,'Acme','todo',id,'human:acme','x','x'
            FROM app
            """)
      }
      #expect(throws: WorkspaceError.self) { try Self.apply(Self.minimal, to: store) }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM app") } == 1)
      try store.write { try $0.database.execute(sql: "DELETE FROM task") }
      try Self.apply(Self.minimal, to: store)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo") } == 0)
    }
  }

  @Test func workspaceSelectionAndMissingSelection() throws {
    try withScratchDirectory { home in
      let store = Self.store(home)
      try Self.apply(Self.minimal, to: store)
      #expect(throws: WorkspaceError.self) { try WorkspaceSelection.resolve(in: store) }
      try WorkspaceSelection.use("acme", in: store)
      #expect(try WorkspaceSelection.resolve(in: store) == "acme")
      #expect(throws: WorkspaceError.self) { try WorkspaceSelection.resolve("absent", in: store) }
    }
  }

  @Test func editorRetriesDiagnosticsThenAppliesAndCleansUp() throws {
    try withScratchDirectory { home in
      let store = Self.store(home)
      let human = try ActorID.detect(
        environment: ["USER": "acme"], terminal: .init(stdin: true, stdout: true), session: "acme")
      var calls = 0
      var temporary: URL?
      let slug = try WorkspaceEditor.edit(
        slug: nil, store: store, actor: human,
        identity: (SeededIDGenerator(seed: 1), Self.instant)
      ) { file in
        calls += 1
        temporary = file
        let before = try String(contentsOf: file, encoding: .utf8)
        if calls == 1 {
          #expect(before.contains("workspace:"))
          try "workspace: []".write(to: file, atomically: true, encoding: .utf8)
        } else {
          #expect(before.hasPrefix("# line"))
          try Self.minimal.write(to: file, atomically: true, encoding: .utf8)
        }
        return 0
      }
      #expect(slug == "acme")
      #expect(calls == 2)
      #expect(!FileManager.default.fileExists(atPath: try #require(temporary).path))
    }
  }

  @Test(arguments: [Int32(0), Int32(1)]) func editorAbortDoesNotWrite(status: Int32) throws {
    try withScratchDirectory { home in
      let store = Self.store(home)
      let human = try ActorID.detect(
        environment: ["USER": "acme"], terminal: .init(stdin: true, stdout: true), session: "acme")
      let result = try WorkspaceEditor.edit(
        slug: nil, store: store, actor: human,
        identity: (SeededIDGenerator(seed: 1), Self.instant)
      ) { _ in status }
      #expect(result == nil)
      #expect(!FileManager.default.fileExists(atPath: store.path))
    }
  }
}
