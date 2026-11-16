import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTopicAliasTests {
  @Test(arguments: [false, true])
  func mixedSpellingsKeepOneIdentityThroughTheWorkflow(aliasFirst: Bool) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try AcmeDocAttachments.apply(
        AcmeDocAttachments.yaml().replacingOccurrences(
          of: "{slug: messaging}", with: "{slug: messaging, aliases: [checkout]}"), to: store)
      let beta = try WorkspaceConfig.parse(
        "workspace: {slug: beta, name: Beta, task_prefix: BE}\n"
          + "topics: [{slug: aaa, aliases: [checkout]}]\n")
      try store.write {
        try beta.apply(in: $0, ids: SeededIDGenerator(seed: 99), at: AcmeDocAttachments.instant)
      }
      let spellings = ["topic:messaging", "topic:CHECKOUT"]
      let refs = aliasFirst ? Array(spellings.reversed()) : spellings
      var request = DocEditRequest(slug: "rules")
      request.title = "Rules"
      request.about = refs
      var failure: (any CodedError)?
      var edited: DocWriteResult?
      do {
        edited = try await DocWritePolicyTests.service(home, store).edit(
          request, input: { "Keep the Acme fallback." })
      } catch let error as any CodedError { failure = error }
      #expect(failure == nil && edited?.ref == "doc:rules@1")
      guard edited != nil else { return }
      let service = DocService(workspace: "acme", store: store)
      #expect(
        try service.list(about: "topic:checkout").output
          == service.list(about: "topic:messaging").output)
      var proposal = DocProposalRequest(slug: "rules", about: refs, why: "Clarify fallback.")
      let writer = try DocProposalServiceTests.service(home, store)
      let proposed = try writer.propose(proposal, input: { "Use the Acme fallback safely." })
      let before = try DocVerificationPreparationTests.truth(store)
      proposal.about = ["topic:messaging"]
      _ = DocProposalServiceTests.refusal(.conflict) {
        _ = try writer.propose(proposal, input: { "Use the Acme fallback safely." })
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      let env = try DocTriageServiceTests.environment(home, store)
      _ = try await DocTriageService(
        environment: env, workspace: "acme", approved: "Accept these Acme rules"
      ).triage(DocTriage(accept: [proposed.ref], reject: []))
      try checkTransport(store, home: home, expected: service.show("rules").output)
    }
  }

  private func checkTransport(_ store: DatabaseStore, home: URL, expected: String) throws {
    try store.read { (db: Database) throws in
      let rows = try Row.fetchAll(db, sql: "SELECT about_refs,about_targets FROM doc_rev")
      for row in rows {
        #expect(row["about_refs"] as String == "[\"topic:messaging\"]")
        let targets = try JSONDecoder().decode(
          [DocTargetIdentity].self, from: Data((row["about_targets"] as String).utf8))
        #expect(targets.count == 1 && targets.first?.kind == "topic")
      }
    }
    let directory = try RestoreSupport.exportTree(store, to: home.appending(path: "export"))
    let destinationHome = home.appending(path: "destination")
    let destination = ExportFixture.store(destinationHome)
    try destination.initialize()
    _ = try RestoreSupport.restore(directory, into: destination, home: destinationHome)
    #expect(
      try DocService(workspace: "acme", store: destination).show("rules").output
        == expected)
  }

  @Test func canonicalTopicsWinWithoutCollapsingDistinctIdentities() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try AcmeDocAttachments.apply(
        AcmeDocAttachments.yaml().replacingOccurrences(
          of: "{slug: messaging}",
          with: "{slug: messaging, aliases: [checkout]}, {slug: billing}"), to: store)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO topic(uid,workspace_id,slug,name)
            VALUES('canonical-checkout',1,'checkout','Checkout')
            """)
      }
      var draft = DocDraft(slug: "rules", body: "Keep distinct Acme topics.")
      draft.title = "Rules"
      draft.about = ["topic:messaging", "topic:checkout", "topic:billing"]
      let metadata = try store.read { try DocMetadata.resolve(draft, workspace: 1, in: $0) }
      #expect(metadata.refs == ["topic:billing", "topic:checkout", "topic:messaging"])
      #expect(Set(metadata.targets.compactMap(\.id)).count == 3)
      let selected = try store.read {
        try TaskLinkTarget.map("topic:checkout", workspace: 1, in: $0)
      }
      #expect(selected.id == metadata.targets.dropFirst().first?.id)
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT uid FROM topic WHERE id=?", arguments: [selected.id])
        } == "canonical-checkout")
    }
  }
}
