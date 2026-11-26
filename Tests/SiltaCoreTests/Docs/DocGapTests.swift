import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocGapTests {
  /// Three apps on one repo: api has edges to web, from mobile and to cache, plus a service edge.
  static let map = """
    workspace: {slug: acme, name: Acme, task_prefix: AC}
    repos: [{slug: platform}]
    apps:
      - {slug: api, repo: platform, ref: main}
      - {slug: web, repo: platform, ref: web}
      - {slug: mobile, repo: platform, ref: mobile}
      - {slug: cache, repo: platform, ref: cache}
    services: [push]
    edges:
      - {from: api, to: web, kind: http-api, summary: Pages}
      - {from: mobile, to: api, kind: http-api, summary: Sign-in}
      - {from: api, to: cache, kind: shared-data, summary: Sessions}
      - {from: api, to: service:push, kind: sdk, summary: Push}
      - {from: web, to: mobile, kind: link, summary: Deep links}
    topics: [{slug: release}]

    """

  /// A claimed task on `app`, or on no app.
  static func setup(_ home: URL, app: String? = "api") async throws -> SiltaEnvironment {
    let env = try TaskServiceTests.environment(home)
    try WorkspaceConfigTests.apply(map, to: env.db)
    try WorkspaceSelection.use("acme", in: env.db)
    var task = TaskDraft(title: "Acme")
    task.start = true
    _ = try await TaskService(environment: env).add(task, directory: home)
    if let app {
      try env.db.write {
        try $0.database.execute(
          sql: "UPDATE task SET app_id=(SELECT id FROM app WHERE slug=?)", arguments: [app])
      }
    }
    return env
  }

  /// An accepted doc about the one edge between `from` and `to`.
  static func document(
    _ slug: String, from: String, to: String, in env: SiltaEnvironment, archived: Bool = false
  ) throws {
    try env.db.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO doc(uid,workspace_id,slug,title,kind,current_rev,archived,
            created_at,updated_at)
          VALUES(?,1,?,'Acme title','reference',1,?,'','');
          INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
          SELECT ?,id,1,'Acme body','accepted','human:acme','' FROM doc WHERE slug=?;
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
            created_by,created_at)
          SELECT ?,1,'doc',doc.id,'about','edge',edge.id,'human:acme',''
          FROM doc, edge JOIN app source ON source.id=edge.from_app_id
          JOIN app target ON target.id=edge.to_app_id
          WHERE doc.slug=? AND source.slug=? AND target.slug=?;
          """,
        arguments: [
          "doc-" + slug, slug, archived, "rev-" + slug, slug, "link-" + slug, slug, from, to,
        ])
      #expect(tx.database.changesCount == 1)
    }
  }

  /// Claims AC-1 again without git: an app task's start records a worktree.
  static func reclaim(_ env: SiltaEnvironment) throws {
    try env.db.write {
      try $0.database.execute(
        sql: "UPDATE task SET status='doing',claimed_by=?,claimed_at=? WHERE seq=1",
        arguments: [env.actor.description, TaskService.timestamp(TaskServiceTests.now)])
    }
  }

  static func gaps(_ env: SiltaEnvironment, app: String = "api") throws -> [String] {
    try env.db.read { db in
      let id = try #require(
        try Int64.fetchOne(db, sql: "SELECT id FROM app WHERE slug=?", arguments: [app]))
      return try DocGaps.appEdges(appID: id, workspaceID: 1, in: db)
    }
  }

  static func message(_ warnings: [OutputWarning]) -> String? {
    warnings.first { $0.code == "doc_gap" }?.message
  }

  @Test func listsUndocumentedAppEdgesInBriefOrderAndIgnoresServicesAndOtherApps() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      #expect(
        try Self.gaps(env) == [
          "edge:api/cache/shared-data", "edge:api/web/http-api", "edge:mobile/api/http-api",
        ])
    }
  }

  @Test func acceptedDocsAndPendingProposalsCoverAnEdgeButArchivedDocsDoNot() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      try Self.document("pages", from: "api", to: "web", in: env)
      try Self.document("sessions", from: "api", to: "cache", in: env, archived: true)
      _ = try DocProposalService(environment: env, workspace: "acme", approved: nil).propose(
        DocProposalRequest(
          slug: "sign-in", title: "Sign-in", about: ["edge:mobile/api/http-api"],
          why: "Share the sign-in contract."),
        input: { "Keep the refresh cookie." })
      #expect(try Self.gaps(env) == ["edge:api/cache/shared-data"])
    }
  }

  @Test func submitWarnsOnceNamingTwoEdgesAndTheRest() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      let result = try TaskService(environment: env).submit("AC-1")
      #expect(result.status == "review")
      #expect(result.warnings.filter { $0.code == "doc_gap" }.count == 1)
      #expect(
        Self.message(result.warnings)
          == "No doc or pending proposal covers edge:api/cache/shared-data, "
          + "edge:api/web/http-api and 1 more. If this work taught something an agent in the "
          + "other app would need, tell the human or propose one: silta --ws 'acme' doc propose "
          + "<slug> --title <title> --about 'edge:api/cache/shared-data' --task 'AC-1' "
          + "-m <why> -F -; otherwise ignore this.")
    }
  }

  @Test func warnsOnlyAtTheTasksFirstSubmitOrHandoff() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      let service = TaskService(environment: env)
      _ = try service.comment("AC-1", CommentDraft(body: "Acme note"))
      #expect(
        Self.message(
          try service.comment("AC-1", CommentDraft(body: "Continue.", kind: "handoff")).warnings)
          != nil)
      try Self.reclaim(env)
      #expect(Self.message(try service.submit("AC-1").warnings) == nil)
      try Self.reclaim(env)
      #expect(
        Self.message(
          try service.comment("AC-1", CommentDraft(body: "Again.", kind: "handoff")).warnings)
          == nil)
    }
  }

  @Test(arguments: ["{not json", "[\"x\"]", "{\"a\":\"b\"}", "[1,{\"kind\":\"edge\"}]"])
  func malformedProposalTargetsNeverAbortTheWrite(snapshot: String) async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      _ = try DocProposalService(environment: env, workspace: "acme", approved: nil).propose(
        DocProposalRequest(
          slug: "sign-in", title: "Sign-in", about: ["edge:mobile/api/http-api"],
          why: "Share the sign-in contract."),
        input: { "Keep the refresh cookie." })
      try env.db.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET about_targets=? WHERE state='proposed'", arguments: [snapshot])
      }
      let result = try TaskService(environment: env).submit("AC-1")
      #expect(result.status == "review")
      #expect(Self.message(result.warnings)?.contains("and 1 more") == true)
    }
  }

  @Test func anUnclaimedHandoffDoesNotUseUpTheOwnersHint() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      let service = TaskService(environment: env)
      try env.db.write {
        try $0.database.execute(sql: "UPDATE task SET claimed_by=NULL,claimed_at=NULL")
      }
      let unclaimed = try service.comment("AC-1", CommentDraft(body: "Context.", kind: "handoff"))
      #expect(unclaimed.warnings.map(\.code) == ["handoff_unclaimed"])
      try Self.reclaim(env)
      let owner = try service.comment("AC-1", CommentDraft(body: "Continue.", kind: "handoff"))
      #expect(Self.message(owner.warnings) != nil)
    }
  }

  @Test func pendingCoverSurvivesAnAppRename() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      _ = try DocProposalService(environment: env, workspace: "acme", approved: nil).propose(
        DocProposalRequest(
          slug: "sign-in", title: "Sign-in", about: ["edge:mobile/api/http-api"],
          why: "Share the sign-in contract."),
        input: { "Keep the refresh cookie." })
      try env.db.write {
        try $0.database.execute(sql: "UPDATE app SET slug='phone' WHERE slug='mobile'")
      }
      #expect(try Self.gaps(env) == ["edge:api/cache/shared-data", "edge:api/web/http-api"])
    }
  }

  @Test(arguments: [nil, "web"] as [String?])
  func submitStaysQuietWithoutAppOrWhenEveryAppEdgeIsCovered(app: String?) async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home, app: app)
      if app != nil {
        try Self.document("pages", from: "api", to: "web", in: env)
        try Self.document("links", from: "web", to: "mobile", in: env)
        #expect(try Self.gaps(env, app: "web").isEmpty)
      }
      #expect(Self.message(try TaskService(environment: env).submit("AC-1").warnings) == nil)
    }
  }

  @Test func onlyTheClaimersHandoffWarns() async throws {
    try await withScratchDirectory { home in
      let env = try await Self.setup(home)
      let service = TaskService(environment: env)
      let note = try service.comment("AC-1", CommentDraft(body: "Acme context"))
      #expect(Self.message(note.warnings) == nil)
      let handoff = try service.comment("AC-1", CommentDraft(body: "Continue.", kind: "handoff"))
      #expect(
        Self.message(handoff.warnings)?.hasPrefix(
          "No doc or pending proposal covers edge:api/cache") == true)
      let unclaimed = try service.comment("AC-1", CommentDraft(body: "Later.", kind: "handoff"))
      #expect(unclaimed.warnings.map(\.code) == ["handoff_unclaimed"])
    }
  }

  @Test func twoGapsReadAsAPair() {
    let warning = DocGaps.warning(["edge:a/b/x", "edge:c/a/y"], workspace: "acme", task: "AC-1")
    #expect(
      warning?.message.hasPrefix(
        "No doc or pending proposal covers edge:a/b/x and edge:c/a/y. ") == true)
    #expect(DocGaps.warning([], workspace: "acme", task: "AC-1") == nil)
    let token = "ghp_" + String(repeating: "A1b2", count: 9)
    let masked = DocGaps.warning(["edge:a/b/x"], workspace: token, task: "AC-1")?.message
    #expect(
      masked?.hasSuffix("tell the human or propose one with --task AC-1; otherwise ignore this.")
        == true)
    #expect(masked?.contains(token) == false)
  }
}
