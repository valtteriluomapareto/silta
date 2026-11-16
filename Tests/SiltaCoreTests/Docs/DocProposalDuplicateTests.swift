import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposalDuplicateTests {
  @Test(arguments: ["base", "pending", "legacy-base"])
  func identicalKnowledgeRefusesWithoutAllocatingOrChangingTruth(kind: String) throws {
    try withScratchDirectory { home in
      let (store, service) = try Self.setup(home, accepted: kind != "pending")
      let body = kind == "pending" ? "Shared café." : "Original"
      if kind == "pending" {
        _ = try service.propose(DocProposalServiceTests.request(), input: { body })
      } else if kind == "legacy-base" {
        try store.write {
          try $0.database.execute(
            sql: "UPDATE doc_rev SET title=NULL,kind=NULL,about_refs=NULL,about_targets=NULL")
        }
      }
      try Self.refuse(service, body: body, existing: "doc:rules@1")
    }
  }

  @Test(arguments: ["body", "unicode-body", "title", "about", "slug", "replacement", "unknown"])
  func meaningfulDifferencesRemainProposable(change: String) throws {
    try withScratchDirectory { home in
      let (store, service) = try Self.setup(home)
      var request = DocProposalServiceTests.request()
      _ = try service.propose(request, input: { "Shared café." })
      if change == "title" { request.title = "Other rules" }
      if change == "about" { request.about = ["topic:messaging"] }
      if change == "slug" { request.slug = "other" }
      if change == "replacement" || change == "unknown" {
        try store.write {
          try $0.database.execute(
            sql: change == "replacement"
              ? "UPDATE service SET uid='replacement' WHERE slug='push'"
              : "UPDATE doc_rev SET about_targets=NULL")
        }
      }
      let body =
        change == "body"
        ? "Changed knowledge."
        : change == "unicode-body"
          ? "Shared cafe\u{301}." : "Shared café."
      let result = Self.attempt(service, request: request, body: body)
      #expect(result?.ref == (change == "slug" ? "doc:other@1" : "doc:rules@2"))
    }
  }

  @Test(arguments: ["rename", "order", "why", "source", "masked"])
  func equivalentMetadataAndFinalBodyDoNotEvadeRefusal(change: String) throws {
    try withScratchDirectory { home in
      let (store, service) = try Self.setup(home)
      var request = DocProposalServiceTests.request()
      if change == "order" { request.about = ["service:push", "topic:messaging"] }
      let body = change == "masked" ? "Password=private123" : "Shared café."
      _ = try service.propose(request, input: { body })
      if change == "rename" {
        try store.write { try $0.database.execute(sql: "UPDATE service SET slug='renamed'") }
        request.about = ["service:renamed"]
      } else if change == "order" {
        request.about = ["topic:messaging", "service:push", "topic:messaging"]
        try store.write {
          try $0.database.execute(
            sql: """
              UPDATE doc_rev SET about_targets=json_array(
                json_extract(about_targets,'$[1]'),json_extract(about_targets,'$[0]'))
              """)
        }
      } else if change == "source" {
        try DocProposalServiceTests.task(store, seq: 1)
        request.task = "AC-1"
      }
      request.why = "Another explanation."
      try Self.refuse(service, request: request, body: body, existing: "doc:rules@1")
    }
  }

  @Test(arguments: ["rejected", "superseded"])
  func terminalOnlyMatchesDoNotPreventNewKnowledge(state: String) throws {
    try withScratchDirectory { home in
      let (store, service) = try Self.setup(home)
      _ = try service.propose(DocProposalServiceTests.request(), input: { "Shared knowledge." })
      try store.write {
        try $0.database.execute(sql: "UPDATE doc_rev SET state=?", arguments: [state])
      }
      let result = Self.attempt(
        service, request: DocProposalServiceTests.request(), body: "Shared knowledge.")
      #expect(result?.ref == "doc:rules@2")
    }
  }

  @Test func unknownHistoricalBaseIsNotInferredFromCurrentMetadata() throws {
    try withScratchDirectory { home in
      let (store, service) = try Self.setup(home, accepted: true)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET title=NULL,kind=NULL,about_refs=NULL,about_targets=NULL")
      }
      var current = DocDraft(slug: "rules", body: "Current knowledge.")
      current.title = "Current title"
      current.kind = "flow"
      current.about = ["app:api"]
      _ = try DocStoreTests.accept(current, in: store, ids: SeededIDGenerator(seed: 83))
      let result = Self.attempt(
        service, request: DocProposalRequest(slug: "rules", base: "1", why: "Revisit history."),
        body: "Original")
      #expect(result?.ref == "doc:rules@3")
    }
  }

  @Test func changedKindIsMeaningfulAgainstHistoricalBase() throws {
    try withScratchDirectory { home in
      let (store, service) = try Self.setup(home, accepted: true)
      var current = DocDraft(slug: "rules", body: "Current knowledge.")
      current.title = "Rules"
      current.kind = "flow"
      current.about = ["service:push"]
      _ = try DocStoreTests.accept(current, in: store, ids: SeededIDGenerator(seed: 83))
      let result = Self.attempt(
        service, request: DocProposalRequest(slug: "rules", base: "1", why: "Update kind."),
        body: "Original")
      #expect(result?.ref == "doc:rules@3")
    }
  }

  @Test func staleKnowledgeCanBeReproposedAndReviewedTogether() async throws {
    try await withScratchDirectory { home in
      let (store, service) = try Self.setup(home, accepted: true)
      let request = DocProposalServiceTests.request()
      let stale = try service.propose(request, input: { "Shared knowledge." }).ref
      var changed = DocDraft(slug: "rules", body: "Different accepted knowledge.")
      changed.title = "Rules"
      changed.about = ["service:push"]
      _ = try DocStoreTests.accept(changed, in: store, ids: SeededIDGenerator(seed: 83))
      let replacement = try #require(
        Self.attempt(service, request: request, body: "Shared knowledge.")?.ref)
      try Self.refuse(service, body: "Shared knowledge.", existing: replacement)
      let result = try await DocTriageService(
        environment: service.environment, workspace: "acme", approved: "Review Acme knowledge"
      ).triage(DocTriage(accept: [replacement], reject: [stale]))
      #expect(result.docs.map(\.state) == ["accepted", "rejected"])
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT current_rev FROM doc") } == 4)
    }
  }

  @Test func duplicatePendingSearchCoversAllActorsAndPages() throws {
    try withScratchDirectory { home in
      let (store, service) = try Self.setup(home, accepted: true)
      try store.write { tx in
        for index in 0..<125 {
          try tx.database.execute(
            sql: "INSERT INTO service(uid,workspace_id,slug,name) VALUES(?,1,?,'Acme candidate')",
            arguments: ["candidate-\(index)", "candidate-\(index)"])
        }
      }
      for index in 0..<125 {
        var request = DocProposalServiceTests.request()
        request.about = ["service:candidate-\(index)"]
        _ = try service.propose(request, input: { "Shared knowledge." })
      }
      let other = Self.otherActor(service)
      let matching = try other.propose(
        DocProposalServiceTests.request(), input: { "Shared knowledge." }
      ).ref
      try AcmeDocAttachments.copyLatestRulesProposal(in: store)
      try Self.refuse(service, body: "Shared knowledge.", existing: matching)
    }
  }

  private static func setup(_ home: URL, accepted: Bool = false) throws
    -> (DatabaseStore, DocProposalService)
  {
    let store = try AcmeDocAttachments.make(in: home)
    if accepted { try DocWritePolicyTests.seed(store) }
    return (store, try DocProposalServiceTests.service(home, store))
  }

  private static func attempt(
    _ service: DocProposalService, request: DocProposalRequest, body: String
  ) -> DocProposalResult? {
    do { return try service.propose(request, input: { body }) } catch {
      Issue.record("Expected a valid proposal: \(error)")
      return nil
    }
  }

  private static func otherActor(_ service: DocProposalService) -> DocProposalService {
    let base = service.environment
    return DocProposalService(
      environment: SiltaEnvironment(
        clock: base.clock, ids: base.ids, git: base.git, home: base.home, db: base.db,
        log: base.log, actor: .agent(tool: "codex", session: "other")), workspace: "acme")
  }

  private static func refuse(
    _ service: DocProposalService, request: DocProposalRequest = DocProposalServiceTests.request(),
    body: String, existing: String
  ) throws {
    let before = try DocVerificationPreparationTests.truth(service.environment.db)
    var failure: (any CodedError)?
    do { _ = try service.propose(request, input: { body }) } catch let error as any CodedError {
      failure = error
    }
    let after = try DocVerificationPreparationTests.truth(service.environment.db)

    #expect(failure?.code == .conflict)
    #expect(failure?.message.contains(existing) == true)
    #expect(failure?.next == ["silta --ws 'acme' doc show '\(existing)'"])
    #expect(before == after)

  }
}
