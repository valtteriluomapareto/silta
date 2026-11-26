import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct BriefDocGapTests {
  static let location = LocationResult(
    path: "/acme", worktree: "/acme", workspace: "acme", repo: "platform",
    app: "api", branch: "main", head: "a", confidence: "high", reason: "single", candidates: [])

  static func sections(_ env: SiltaEnvironment, compact: Bool, topics: [String] = [])
    throws -> [BriefSection]
  {
    var location = Self.location
    location.currentTask = try env.db.read {
      try TaskService.lookup("AC-1", workspace: "acme", in: $0)
    }
    return try env.db.read {
      try BriefContext(
        db: $0, location: BriefLocation(location), actor: TaskServiceTests.agent,
        date: TaskServiceTests.now, archiveDays: 14
      ).sections(topics: topics, compact: compact).sections
    }
  }

  /// The item text each annotation follows, paired with the annotation, after fitting.
  static func placed(_ sections: [BriefSection], tokens: Int = 2500) -> [(String, String)] {
    var report = BriefDocsTests.report(sections, location: Self.location, tokens: tokens)
    report.insertDocuments(tokens: tokens)
    var item = ""
    var pairs: [(String, String)] = []
    for section in report.sections {
      if section.id == "docs" { pairs.append((item, section.text)) } else { item = section.text }
    }
    return pairs
  }

  static func annotations(_ sections: [BriefSection], tokens: Int = 2500) -> [String] {
    var report = BriefDocsTests.report(sections, location: Self.location, tokens: tokens)
    report.insertDocuments(tokens: tokens)
    return report.sections.filter { $0.id == "docs" }.map(\.text)
  }

  /// api: only an archived app doc; api→web documented; mobile→api pending; api→cache
  /// open; push service documented.
  static func mixed(_ home: URL) async throws -> SiltaEnvironment {
    let env = try await DocGapTests.setup(home)
    try DocGapTests.document("pages", from: "api", to: "web", in: env)
    _ = try DocProposalService(environment: env, workspace: "acme", approved: nil).propose(
      DocProposalRequest(
        slug: "sign-in", title: "Sign-in", about: ["edge:mobile/api/http-api"],
        why: "Share the sign-in contract."),
      input: { "Keep the refresh cookie." })
    try env.db.write {
      try $0.database.execute(
        sql: """
          INSERT INTO doc(uid,workspace_id,slug,title,kind,current_rev,archived,
            created_at,updated_at)
          VALUES('doc-push',1,'push','Push','reference',1,0,'','');
          INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
          SELECT 'rev-push',id,1,'Retry pushes.','accepted','human:acme',''
          FROM doc WHERE slug='push';
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
            created_by,created_at)
          SELECT 'link-push',1,'doc',doc.id,'about','service',service.id,'human:acme',''
          FROM doc, service WHERE doc.slug='push' AND service.slug='push';
          INSERT INTO doc(uid,workspace_id,slug,title,kind,current_rev,archived,
            created_at,updated_at)
          VALUES('doc-old',1,'old','Old','reference',1,1,'','');
          INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
          SELECT 'rev-old',id,1,'Retired.','accepted','human:acme','' FROM doc WHERE slug='old';
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
            created_by,created_at)
          SELECT 'link-old',1,'doc',doc.id,'about','app',app.id,'human:acme',''
          FROM doc, app WHERE doc.slug='old' AND app.slug='api';
          """)
    }
    return env
  }

  @Test(arguments: [false, true])
  func uncoveredAppAndEdgesShowNoneBesideTheirItems(compact: Bool) async throws {
    try await withScratchDirectory { home in
      let env = try await Self.mixed(home)
      let sections = try Self.sections(env, compact: compact, topics: ["release"])
      let none = Self.placed(sections).filter { $0.1 == "docs: none\n" }.map(\.0)
      #expect(none == ["app: api\n", "neighbour: edge:api/cache/shared-data Sessions\n"])
      let text = Self.annotations(sections).joined()
      #expect(text.contains("edge:api/web/http-api") && text.contains("service:push"))
      #expect(!text.contains("mobile/api") && !text.contains("topic:release"))
    }
  }

  @Test func pendingAppProposalCoversAndUndocumentedServiceEdgesShowNone() async throws {
    try await withScratchDirectory { home in
      let env = try await DocGapTests.setup(home)
      _ = try DocProposalService(environment: env, workspace: "acme", approved: nil).propose(
        DocProposalRequest(slug: "api", title: "API", about: ["app:api"], why: "Share it."),
        input: { "Keep the API small." })
      let none = Self.placed(try Self.sections(env, compact: false))
        .filter { $0.1 == "docs: none\n" }.map(\.0)
      #expect(!none.contains("app: api\n"))
      #expect(none.contains("neighbour: edge:api/service:push/sdk Push\n"))
    }
  }

  @Test(arguments: ["{not json", "[\"x\"]", "{\"a\":\"b\"}", "[1,{\"kind\":\"edge\"}]"])
  func malformedSnapshotsAreNoCoverAndNeverFailTheBrief(snapshot: String) async throws {
    try await withScratchDirectory { home in
      let env = try await DocGapTests.setup(home)
      _ = try DocProposalService(environment: env, workspace: "acme", approved: nil).propose(
        DocProposalRequest(slug: "api", title: "API", about: ["app:api"], why: "Share it."),
        input: { "Keep the API small." })
      try env.db.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET about_targets=? WHERE state='proposed'", arguments: [snapshot])
      }
      let none = Self.placed(try Self.sections(env, compact: true)).filter {
        $0.1 == "docs: none\n"
      }
      #expect(none.map(\.0).first == "app: api\n")
    }
  }

  @Test func storesWithoutSnapshotColumnsStillBrief() async throws {
    try await withScratchDirectory { home in
      let env = try await DocGapTests.setup(home)
      try env.db.write {
        try $0.database.execute(sql: "ALTER TABLE doc_rev DROP COLUMN about_targets")
      }
      #expect(Self.placed(try Self.sections(env, compact: true)).count == 5)
      #expect(try DocGapTests.gaps(env).count == 3)
    }
  }

  @Test func coveredItemsDroppedForBudgetNeverReadAsNone() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.mixed(home)
      let sections = try Self.sections(env, compact: false)
      for tokens in [1, 20, 40, 60, 80, 120, 2500] {
        let placed = Self.placed(sections, tokens: tokens)
        #expect(
          !placed.contains { $0.0.hasPrefix("neighbour: edge:api/web") && $0.1 == "docs: none\n" })
        #expect(
          !placed.contains {
            $0.0.hasPrefix("neighbour: edge:api/service:push") && $0.1 == "docs: none\n"
          })
      }
    }
  }

  @Test func gapLinesNeverChangeRealAnnotationsAndOmissionKeepsTruncated() {
    let real = BriefDocGroup(
      ref: "edge:api/web/http-api", workspace: "acme", total: 3,
      rows: ["  doc:pages [contract] " + String(repeating: "x", count: 100) + "\n"])
    var reachedOmission = false
    for compact in [false, true] {
      for tokens in 1...600 {
        let gaps = [
          BriefDocGroup.gap(ref: "app:api", workspace: "acme"),
          BriefDocGroup.gap(ref: "edge:api/cache/shared-data", workspace: "acme"),
        ]
        let shown =
          compact ? BriefDocGroup(ref: real.ref, workspace: "acme", total: 3, rows: []) : real
        let tasks = (1...6).map {
          BriefSection(id: "open_tasks", text: "open: AC-\($0) Acme context and more\n")
        }
        let with =
          [BriefSection(id: "app", text: "app: api\n", documents: [gaps[0]])]
          + [BriefSection(id: "neighbours", text: "neighbour: cache\n", documents: [gaps[1]])]
          + [BriefSection(id: "neighbours", text: "neighbour: web\n", documents: [shown])]
          + tasks
        let without = with.map { section in
          var copy = section
          copy.documents = section.documents.filter { !$0.isGap }
          return copy
        }
        var plain = BriefDocsTests.report(without, location: Self.location, tokens: tokens)
        var marked = BriefDocsTests.report(with, location: Self.location, tokens: tokens)
        let fitted = !marked.truncated
        plain.insertDocuments(tokens: tokens)
        marked.insertDocuments(tokens: tokens)
        let real = { (report: BriefReport) in
          report.sections.filter { $0.id == "docs" && $0.text != "docs: none\n" }.map(\.text)
        }
        #expect(real(marked) == real(plain))
        #expect(marked.docsShown == plain.docsShown && marked.docsCounted == plain.docsCounted)
        let gapsShown = marked.sections.filter { $0.text == "docs: none\n" }.count
        if compact && fitted && !real(marked).isEmpty && gapsShown < 2 {
          reachedOmission = true
          #expect(marked.truncated)
        }
      }
    }
    #expect(reachedOmission)
  }

  @Test func gapLinesCarryNoCommandEvenInSecretBearingWorkspaces() {
    let token = "ghp_" + String(repeating: "A1b2", count: 9)
    for workspace in ["acme", token] {
      #expect(
        BriefDocGroup.gap(ref: "app:api", workspace: workspace).choices.map(\.text)
          == ["docs: none\n"])
    }
  }
}
