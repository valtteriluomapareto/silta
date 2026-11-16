import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTopicAliasTests {
  @Test(arguments: [false, true])
  func mixedSpellingsKeepOneIdentityThroughTheWorkflow(aliasFirst: Bool) async throws {
    await withKnownIssue("Document guidance and recovery preserve the requested contract.") {
      try await withScratchDirectory { home in
        let store = try AcmeDocAttachments.make(in: home)
        try AcmeDocAttachments.apply(
          AcmeDocAttachments.yaml().replacingOccurrences(
            of: "{slug: messaging}", with: "{slug: messaging, aliases: [checkout]}"), to: store)
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
            == service.show("rules").output)
      }
    }
  }
}
