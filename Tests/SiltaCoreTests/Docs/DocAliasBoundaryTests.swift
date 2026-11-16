import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocAliasBoundaryTests {
  @Test(arguments: ["canonical", "alias"], [false, true])
  func nulSuffixNeverSelectsThePrefix(kind: String, exact: Bool) async throws {
    await withKnownIssue(
      "Topic aliases preserve complete lookup bytes and canonical identity policy."
    ) {
      try await withScratchDirectory { home in
        let store = try fixture(home)
        try AcmeDocAttachments.attach("rules", to: "topic", in: store)
        let value = (kind == "canonical" ? "messaging" : "CHECKOUT") + "\u{0}tail"
        if exact { try fullAlias(WorkspaceConfig.normalize(value), in: store) }
        let before = try DocVerificationPreparationTests.truth(store)
        let environment = try DocTriageServiceTests.environment(home, store)
        try checkReads("topic:" + value, exact: exact, store: store)
        #expect(try DocVerificationPreparationTests.truth(store) == before)
        for operation in ["propose", "edit"] {
          var failure: (any CodedError)?
          do {
            _ = try await invoke(operation, about: "topic:" + value, environment: environment)
          } catch let error as any CodedError { failure = error }
          if exact {
            #expect(failure == nil)
            #expect(try targetUID("candidate-" + operation, store: store) == "full-alias")
          } else {
            #expect(failure?.code == .notFound)
            #expect(try DocVerificationPreparationTests.truth(store) == before)
          }
        }
      }
    }
  }

  @Test(arguments: ["propose", "edit"])
  func canonicalAndAliasShareIdentityAdmission(operation: String) async throws {
    await withKnownIssue(
      "Topic aliases preserve complete lookup bytes and canonical identity policy."
    ) {
      try await withScratchDirectory { home in
        let store = try fixture(home)
        let sensitive = "AKIA" + String(repeating: "A", count: 16)
        try store.write {
          try $0.database.execute(sql: "UPDATE topic SET slug=?", arguments: [sensitive])
        }
        let before = try DocVerificationPreparationTests.truth(store)
        let environment = try DocTriageServiceTests.environment(home, store)
        for about in ["topic:" + sensitive, "topic:checkout"] {
          var failure: (any CodedError)?
          do { _ = try await invoke(operation, about: about, environment: environment) } catch let
            error as any CodedError
          { failure = error }
          #expect(
            failure?.code == .invalid
              && failure?.message.hasPrefix("Secret content detected:") == true)
          #expect(try DocVerificationPreparationTests.truth(store) == before)
        }
      }
    }
  }

  @Test func allowedAndRetainedCanonicalRefsRemainUsable() async throws {
    try await withScratchDirectory { home in
      let store = try fixture(home)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE topic SET slug=?", arguments: ["AKIA" + String(repeating: "A", count: 16)])
      }
      let editor = try DocWritePolicyTests.service(home, store, human: true, approved: nil)
      let request = DocEditRequest(
        slug: "rules", title: "Rules", about: ["topic:checkout"], allowSecret: true)
      _ = try await editor.edit(request, input: { "Password=private123" })
      var keep = DocEditRequest(slug: "rules")
      keep.keepBody = true
      _ = try await editor.edit(keep, input: nil)
      _ = try DocProposalService(environment: editor.environment, workspace: "acme").propose(
        DocProposalRequest(slug: "rules", why: "Clarify the rule."),
        input: { "New safe Acme rule." })
      #expect(
        try store.read {
          try Data.fetchOne($0, sql: "SELECT CAST(body_md AS BLOB) FROM doc_rev WHERE rev=2")
        } == Data("Password=private123".utf8))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM doc_rev") } == 3)
    }
  }

  private func fixture(_ home: URL) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: home)
    try AcmeDocAttachments.apply(
      AcmeDocAttachments.yaml().replacingOccurrences(
        of: "{slug: messaging}", with: "{slug: messaging, aliases: [checkout]}"), to: store)
    return store
  }

  private func fullAlias(_ value: String, in store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql: """
          INSERT INTO topic(uid,workspace_id,slug,name) VALUES('full-alias',1,'billing','Billing')
          """)
      try $0.database.execute(
        sql: "INSERT INTO topic_alias(workspace_id,topic_id,alias) VALUES(1,2,CAST(? AS TEXT))",
        arguments: [Data(value.utf8)])
    }
    try #require(
      try store.read {
        try Data.fetchOne($0, sql: "SELECT CAST(alias AS BLOB) FROM topic_alias WHERE topic_id=2")
      } == Data(value.utf8))
  }

  private func checkReads(_ raw: String, exact: Bool, store: DatabaseStore) throws {
    var target: TaskLinkTarget?
    var failure: (any CodedError)?
    do { target = try store.read { try TaskLinkTarget.map(raw, workspace: 1, in: $0) } } catch let
      error as any CodedError
    { failure = error }
    #expect(exact ? target?.id == 2 && failure == nil : target == nil && failure?.code == .notFound)
    var page: DocListResult?
    failure = nil
    do { page = try DocService(workspace: "acme", store: store).list(about: raw) } catch let error
      as any CodedError
    { failure = error }
    #expect(exact ? page?.entries.isEmpty == true && failure == nil : failure?.code == .notFound)
  }

  private func invoke(_ operation: String, about: String, environment: SiltaEnvironment)
    async throws
    -> String
  {
    let slug = "candidate-" + operation
    if operation == "propose" {
      return try DocProposalService(environment: environment, workspace: "acme").propose(
        DocProposalRequest(slug: slug, title: "Rules", about: [about], why: "Share Acme."),
        input: { "Safe Acme knowledge." }
      ).ref
    }
    return try await DocWriteService(
      environment: environment, workspace: "acme", approved: "Keep these Acme rules"
    ).edit(
      DocEditRequest(slug: slug, title: "Rules", about: [about]),
      input: { "Safe Acme knowledge." }
    ).ref
  }

  private func targetUID(_ slug: String, store: DatabaseStore) throws -> String? {
    try store.read {
      try String.fetchOne(
        $0,
        sql: """
          SELECT json_extract(r.about_targets,'$[0].uid') FROM doc_rev r
          JOIN doc d ON d.id=r.doc_id WHERE d.slug=?
          """, arguments: [slug])
    }
  }
}
