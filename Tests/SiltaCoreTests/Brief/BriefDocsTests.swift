import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

struct BriefDocsTests {
  static func location(_ home: URL, store: DatabaseStore) throws -> LocationResult {
    var location = LocationResult(
      path: home.path, worktree: home.path, workspace: "acme", repo: "platform", app: "api",
      branch: "main", head: "a", confidence: "high", reason: "single", candidates: [])
    location.currentTask = try store.read {
      try TaskService.lookup("AC-1", workspace: "acme", in: $0)
    }
    return location
  }

  static func setup(_ home: URL) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: home)
    try store.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO task(id,uid,workspace_id,seq,title,status,app_id,created_by,created_at,updated_at)
          VALUES(1,'task',1,1,'Handle push','doing',1,'human:acme','','');
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
          VALUES('task-topic',1,'task',1,'about','topic',1,'human:acme','');
          """)
    }
    return store
  }

  static func document(_ slug: String, target: String, body: String, store: DatabaseStore) throws {
    try AcmeDocAttachments.attach(slug, to: target, in: store)
    try store.write {
      try $0.database.execute(
        sql: "UPDATE doc_rev SET body_md=? WHERE doc_id=(SELECT id FROM doc WHERE slug=?)",
        arguments: [body, slug])
    }
  }

  static func context(
    _ store: DatabaseStore, location: LocationResult, compact: Bool = false,
    topics: [String] = []
  ) throws -> [BriefSection] {
    try store.read {
      try BriefContext(
        db: $0, location: location, actor: TaskServiceTests.agent,
        date: AcmeDocAttachments.instant, archiveDays: 14
      ).sections(topics: topics, compact: compact).sections
    }
  }

  static func report(_ sections: [BriefSection], location: LocationResult, tokens: Int = 2500)
    -> BriefReport
  {
    var report = BriefReport(
      location: BriefLocation(location),
      settings: BriefSettings(WorkspaceSettings(workspace: "acme", json: "{}"), workspace: "acme"),
      currentTask: "AC-1", sections: sections, more: ["silta --ws 'acme' task show AC-1"],
      warnings: [])
    report.trim(tokens: tokens)
    return report
  }

  @Test func currentDocumentsAppearAtEveryOwnedMapItem() throws {
    try withScratchDirectory { home in
      let store = try Self.setup(home)
      try Self.document(
        "app-guide", target: "app", body: "# Heading\n\nUse app conventions.", store: store)
      try Self.document(
        "interface", target: "edge", body: "Keep unknown categories visible.", store: store)
      try AcmeDocAttachments.attach("interface", to: "service", in: store)
      try Self.document("topic-rule", target: "topic", body: "Coordinate messaging.", store: store)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET kind='contract' WHERE slug='interface'")
      }
      let location = try Self.location(home, store: store)
      let sections = try Self.context(store, location: location)
      #expect(
        sections.flatMap(\.documents).map(\.ref) == [
          "app:api", "edge:api/service:push/sdk", "service:push", "topic:messaging",
        ])
      var report = Self.report(sections, location: location)
      report.insertDocuments(tokens: 2500)
      Golden.forTests().check(report.text, "brief-docs.txt")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      Golden.forTests().check(
        String(decoding: try encoder.encode(report), as: UTF8.self) + "\n", "brief-docs.json")
    }
  }

  @Test func ranksRealTaskTopicsAndExcludesUnacceptedArchivedAndHistoricalRows() throws {
    try withScratchDirectory { home in
      let store = try Self.setup(home)
      for slug in ["alpha", "beta", "zeta"] {
        try Self.document(slug, target: "app", body: "Current " + slug, store: store)
      }
      try AcmeDocAttachments.attach("zeta", to: "topic", in: store)
      try AcmeDocAttachments.attach("pending", to: "app", in: store, state: "proposed")
      try AcmeDocAttachments.attach("archived", to: "app", in: store, archived: true)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
            SELECT 'history',id,2,'Obsolete body','accepted','human:acme','' FROM doc WHERE slug='alpha';
            INSERT INTO workspace(id,uid,slug,name,task_prefix) VALUES(2,'beta-ws','beta','Beta','BE');
            INSERT INTO doc(id,uid,workspace_id,slug,title,kind,current_rev,created_at,updated_at)
            VALUES(90,'foreign',2,'foreign','Foreign','reference',1,'','');
            INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
            VALUES('foreign-rev',90,1,'Foreign body','accepted','human:acme','');
            INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
            VALUES('foreign-link',1,'doc',90,'about','app',1,'human:acme','');
            """)
      }
      let groups = try Self.context(store, location: Self.location(home, store: store)).flatMap(
        \.documents)
      let app = try #require(groups.first { $0.ref == "app:api" })
      #expect(app.total == 3 && app.rows.count == 2)
      #expect(app.rows[0].contains("doc:zeta") && app.rows[1].contains("doc:alpha"))
      #expect(app.rows[1].contains("Current alpha"))
      #expect(!groups.flatMap(\.rows).joined().contains("Obsolete"))
    }
  }

  @Test(arguments: [false, true]) func compactCountsDoNotReadBodies(compact: Bool) throws {
    try withScratchDirectory { home in
      let store = try Self.setup(home)
      try Self.document("guide", target: "app", body: "Read this committed rule.", store: store)
      let location = try Self.location(home, store: store)
      try store.read { db in
        var statements: [String] = []
        db.trace { if case .statement(let statement) = $0 { statements.append(statement.sql) } }
        let context = try BriefContext(
          db: db, location: location, actor: TaskServiceTests.agent,
          date: AcmeDocAttachments.instant, archiveDays: 14
        ).sections(topics: [], compact: compact)
        db.trace(nil)
        #expect(context.sections.flatMap(\.documents).first?.total == 1)
        let readsBody = try statements.contains {
          try db.makeStatement(sql: $0).databaseRegion.isModified(
            byEventsOfKind:
              .update(tableName: "doc_rev", columnNames: ["body_md"]))
        }
        #expect(readsBody == !compact)
      }
    }
  }

  @Test func masksMetadataAndBodyBeforeUnicodeSummaryClipping() throws {
    try withScratchDirectory { home in
      let store = try Self.setup(home)
      let body =
        "# Heading\n\n" + String(repeating: "👩🏽‍💻", count: 115) + "AKIA"
        + String(repeating: "A", count: 16)
      try Self.document("guide", target: "app", body: body, store: store)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc SET kind='Pwd=kind-secret',title='Pwd=title-secret'")
      }
      let row = try #require(
        try Self.context(store, location: Self.location(home, store: store))
          .flatMap(\.documents).first?.rows.first)
      let prefix = "  doc:guide [[REDACTED:password]] "
      #expect(row.hasPrefix(prefix))
      #expect(
        !row.contains("kind-secret") && !row.contains("title-secret") && !row.contains("AKIA"))
      let summary = String(row.dropFirst(prefix.count)).trimmingCharacters(in: .newlines)
      #expect(summary.count == 120 && summary.hasSuffix("[REDA"))
    }
  }

  @Test func documentBudgetPreservesEveryBaselineRowAndCompleteCommands() {
    let home = URL(filePath: "/acme")
    let location = LocationResult(
      path: home.path, worktree: home.path, workspace: "acme", repo: "platform",
      app: "api", branch: "main", head: "a", confidence: "high", reason: "single", candidates: [])
    for compact in [false, true] {
      for tokens in [1, 40, 80, 160, 320, 800, 2500] {
        let ref = "service:" + String(repeating: "push%20", count: 15)
        let group = BriefDocGroup(
          ref: ref, workspace: "acme", total: 50,
          rows: compact
            ? [] : ["  doc:first [reference] " + String(repeating: "x", count: 120) + "\n"])
        let sections =
          [BriefSection(id: "app", text: "app: api\n", documents: [group])]
          + (1...8).map { BriefSection(id: "open_tasks", text: "open: AC-\($0) Acme task\n") }
        let baseline = Self.report(sections, location: location, tokens: tokens)
        var report = baseline
        report.insertDocuments(tokens: tokens)
        #expect(report.sections.filter { $0.id != "docs" } == baseline.sections)
        let docs = report.sections.filter { $0.id == "docs" }.map(\.text).joined()
        #expect(docs.count <= tokens * 4 / 5)
        #expect(report.text.count <= max(tokens * 4, baseline.text.count))
        #expect(report.truncated)
        if !docs.isEmpty { #expect(docs.contains("doc ls --about '") && docs.hasSuffix(")\n")) }
      }
    }
  }
}
