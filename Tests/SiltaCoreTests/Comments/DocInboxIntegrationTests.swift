import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct DocInboxIntegrationTests {
  @Test(arguments: [false, true], [false, true])
  func documentGroupsShareCapAndCountMembersSeparately(all: Bool, human: Bool) throws {
    try withScratchDirectory { home in
      let actor: ActorID = human ? .human(name: "acme") : TaskServiceTests.agent
      let (store, service) = try fixture(home, groups: 14, actor: actor)
      let before = try DocVerificationPreparationTests.truth(store)
      let observed = try observedInbox(service, store: store, actor: actor, all: all)
      let result = observed.result
      let shown = human ? (all ? 14 : 12) : 0
      #expect(result.items.count == shown)
      #expect(observed.rows.groups == shown && observed.rows.members == shown * 2)
      #expect(result.remaining == (human && !all ? 2 : 0))
      #expect(result.items.allSatisfy { $0.kind == "doc_proposal" })
      let objects = try items(result)
      let groups = objects.compactMap { $0["doc_proposal"] as? [String: Any] }
      #expect(groups.count == shown)
      for group in groups {
        #expect(Set(group.keys) == ["ref", "total", "omitted", "members", "next"])
        #expect(group["total"] as? Int == 3 && group["omitted"] as? Int == 1)
        let members = try #require(group["members"] as? [[String: Any]])
        #expect(members.count == 2)
        #expect(
          members.allSatisfy { ($0["summary"] as? String)?.hasPrefix("body changed") == true })
        #expect(members.allSatisfy { $0["read"] is String })
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test func taskAndDocumentTiesKeepExistingOrder() async throws {
    try await withScratchDirectory { home in
      let (store, service) = try fixture(home, groups: 2)
      for _ in 0..<2 { _ = try await InboxGroupTests.add(service, home) }
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE task SET status='proposed',created_by='agent:codex:writer';
            UPDATE doc SET uid=CASE slug WHEN 'rules' THEN 'a' ELSE 'A' END;
            """)
      }
      let result = try service.inbox()
      #expect(result.items.map(\.kind) == ["proposal", "proposal", "doc_proposal", "doc_proposal"])
      #expect(result.items.compactMap(\.ref) == ["AC-2", "AC-1", "doc:rules1", "doc:rules"])
    }
  }

  @Test(arguments: [false, true])
  func earlierCategoriesReduceDocumentWindow(blockers: Bool) async throws {
    try await withScratchDirectory { home in
      let (store, service) = try fixture(home, groups: 14)
      for _ in 0..<(blockers ? 9 : 8) { _ = try await InboxGroupTests.add(service, home) }
      if blockers {
        for seq in 2...9 { try InboxGroupTests.block(service, "AC-\(seq)", ["AC-1"], "7d") }
        try store.write {
          try $0.database.execute(sql: "UPDATE task SET status='done' WHERE seq=1")
        }
      } else {
        try store.write {
          try $0.database.execute(
            sql: "UPDATE task SET status='proposed',created_by='agent:codex:writer'")
        }
      }
      let observed = try observedInbox(service, store: store)
      let result = observed.result
      #expect(observed.rows.groups == (blockers ? 4 : 12) && observed.rows.members == 8)
      #expect(result.items.count == 12 && result.remaining == 10)
      #expect(result.items.prefix(8).allSatisfy { $0.kind == (blockers ? "ready" : "proposal") })
      #expect(result.items.suffix(4).allSatisfy { $0.kind == "doc_proposal" })
      let groups = try items(result).compactMap { $0["doc_proposal"] as? [String: Any] }
      #expect(groups.count == 4)
      #expect(groups.compactMap { $0["members"] as? [[String: Any]] }.flatMap { $0 }.count == 8)
    }
  }

  @Test(arguments: [13.0, 14.0, 15.0])
  func publicAttentionUsesStrictProposalWindow(days: Double) throws {
    try withScratchDirectory { home in
      let (_, service) = try fixture(home, groups: 1, days: days)
      #expect(try service.inbox().items.count == (days < 14 ? 1 : 0))
      let all = try service.inbox(all: true)
      #expect(all.items.count == 1 && all.remaining == 0)
    }
  }

  @Test(arguments: ["v1", "v2", "v3", "v4"])
  func genuineHistoricalGroupsKeepUnknownEvidenceWithoutMigration(version: String) throws {
    try withScratchDirectory { home in
      let (store, _) = try DocLegacyEvidenceReadTests().fixture(home, version: version)
      let before = try DocVerificationPreparationTests.truth(store)
      let result = try service(store, home: home).inbox()
      #expect(result.items.count == 1 && result.remaining == 0)
      let group = try #require(try items(result).first?["doc_proposal"] as? [String: Any])
      let members = try #require(group["members"] as? [[String: Any]])
      let member = try #require(members.first)
      #expect(member["title"] as? String == "(unknown)" && member["kind"] as? String == "(unknown)")
      #expect(member["source_task"] as? String == "(not recorded)")
      #expect((member["summary"] as? String)?.contains("unknown") == true)
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  func observedInbox(
    _ service: TaskService, store: DatabaseStore, actor: ActorID = .human(name: "acme"),
    all: Bool = false
  ) throws -> (result: InboxResult, rows: (groups: Int, members: Int)) {
    try store.read { db in
      var sql: [String] = []
      db.trace { if case .statement(let statement) = $0 { sql.append(statement.expandedSQL) } }
      defer { db.trace(nil) }
      let result = try service.inbox(
        for: actor, workspace: "acme", all: all, at: AcmeDocAttachments.instant, in: db)
      db.trace(nil)
      let groups = try sql.filter { $0.contains("ORDER BY newest DESC") }
        .map { try Row.fetchAll(db, sql: $0).count }.reduce(0, +)
      let members = try sql.filter { $0.contains("WITH eligible AS") }
        .map { try Row.fetchAll(db, sql: $0).count }.reduce(0, +)
      return (result, (groups, members))
    }
  }

  func fixture(
    _ home: URL, groups: Int, actor: ActorID = .human(name: "acme"), days: Double = 0
  ) throws -> (DatabaseStore, TaskService) {
    let docs = DocProposalInboxTests()
    let store = try docs.fixture(home)
    for index in 1..<groups {
      try AcmeDocAttachments.attach("rules\(index)", to: "app", in: store)
    }
    for index in 0..<groups {
      try docs.add(3, doc: index == 0 ? "rules" : "rules\(index)", days: days, in: store)
    }
    return (store, try service(store, home: home, actor: actor))
  }

  func service(_ store: DatabaseStore, home: URL, actor: ActorID = .human(name: "acme")) throws
    -> TaskService
  {
    let env = SiltaEnvironment(
      clock: FakeClock(now: AcmeDocAttachments.instant), ids: SeededIDGenerator(seed: 7),
      git: ScriptedGitRunner(script: []),
      home: try SiltaHome.resolve(environment: [
        "SILTA_HOME": home.appending(path: "silta-home").path
      ]),
      db: store, log: FakeLog(), actor: actor)
    return TaskService(environment: env, workspace: "acme")
  }

  func items(_ result: InboxResult) throws -> [[String: Any]] {
    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
    return try #require(object["items"] as? [[String: Any]])
  }
}
