import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocProposalReferenceTests {
  @Test(arguments: [false, true], ["explicit", "current", "prepared"])
  func pinnedTargetIsInvalidBeforeCreationMetadataAndOffersValidRetry(
    metadata: Bool, selection: String
  ) throws {
    withKnownIssue("SI-126/33: printed doc references must recover without loops") {
      try withScratchDirectory { home in
        let store = try AcmeDocAttachments.make(in: home)
        try DocWritePolicyTests.seed(store)
        var environment = try DocProposalServiceTests.service(home, store).environment
        if selection == "prepared" { environment.workspaceSelection = .success("acme") }
        try store.write {
          try $0.database.execute(
            sql:
              "INSERT INTO meta(key,value) VALUES('current_workspace','acme') ON CONFLICT(key) DO UPDATE SET value='acme'"
          )
        }
        let service = DocProposalService(
          environment: environment, workspace: selection == "explicit" ? "acme" : nil)
        let request = DocProposalRequest(
          slug: "doc:rules@1", title: metadata ? "Rules" : nil,
          about: metadata ? ["service:push"] : nil, why: "Share")
        let before = try DocVerificationPreparationTests.truth(store)
        var read = false
        let error = try #require(
          DocProposalServiceTests.refusal(.invalid) {
            _ = try service.propose(request) {
              read = true
              return "New knowledge"
            }
          })
        #expect(read)
        #expect(error.next == [Self.retry])
        #expect(!error.message.contains("Missing required"))
        #expect(try DocVerificationPreparationTests.truth(store) == before)
      }
    }
  }

  @Test(arguments: [
    "rules@0", "rules@01", "rules@-1", "doc:rules", "rules@1/2", "rules@1#L2", "rules@@1",
  ])
  func malformedTargetsUseDiscoveryWithoutRepeatingAWrite(slug: String) throws {
    withKnownIssue("SI-126/33: printed doc references must recover without loops") {
      try withScratchDirectory { home in
        let store = try AcmeDocAttachments.make(in: home)
        let before = try DocVerificationPreparationTests.truth(store)
        let error = try #require(
          DocProposalServiceTests.refusal(.invalid) {
            _ = try DocProposalServiceTests.service(home, store).propose(
              DocProposalRequest(slug: "doc:" + slug, why: "Share"), input: { "Body" })
          })
        #expect(error.next == ["silta --ws 'acme' doc ls"])
        #expect(try DocVerificationPreparationTests.truth(store) == before)
      }
    }
  }

  @Test(arguments: ["doc:rules@1", "doc:rules@2"])
  func printedAcceptedBaseWorksWithoutRetargeting(base: String) throws {
    withKnownIssue("SI-126/33: printed doc references must recover without loops") {
      try withScratchDirectory { home in
        let store = try Self.history(home)
        var result: DocProposalResult?
        var failure: (any CodedError)?
        do {
          result = try DocProposalServiceTests.service(home, store).propose(
            DocProposalRequest(slug: "rules", base: base, why: "Share"), input: { "Proposal" })
        } catch let error as any CodedError { failure = error }
        #expect(failure == nil)
        #expect(result?.ref == "doc:rules@3")
        if result != nil {
          let row = try DocProposalServiceTests.row(store, revision: 3)
          #expect(row["base_rev"] as Int == (base.hasSuffix("@1") ? 1 : 2))
          #expect(row["title"] as String == "Current title")
          #expect(
            try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 0)
        }
      }
    }
  }

  @Test(arguments: ["+1", "01", "2"])
  func existingPositiveNumericBaseFormsRemainCompatible(base: String) throws {
    try withScratchDirectory { home in
      let store = try Self.history(home)
      let result = try DocProposalServiceTests.service(home, store).propose(
        DocProposalRequest(slug: "rules", base: base, why: "Share"), input: { "Proposal" })
      #expect(result.ref == "doc:rules@3")
      #expect(try DocProposalServiceTests.row(store, revision: 3)["base_rev"] as Int == Int(base))
    }
  }

  @Test(arguments: [
    "doc:other@1", "doc:rules@3", "doc:rules@4", "doc:rules@5", "doc:rules@99", "doc:rules@0",
    "doc:rules@01", "doc:rules@1/2", "doc:doc:rules@1",
  ])
  func typedBaseRequiresThisOwnedDocAndAcceptedCanonicalRevision(base: String) throws {
    let check = { () throws in
      try withScratchDirectory { home in
        let store = try Self.history(home)
        try store.write {
          for (number, state) in [(3, "proposed"), (4, "rejected"), (5, "superseded")] {
            try $0.database.execute(
              sql:
                "INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at) VALUES(?,1,?,'Other',?,'human:acme','')",
              arguments: ["revision-\(number)", number, state])
          }
          try $0.database.execute(
            sql:
              "INSERT INTO doc(uid,workspace_id,slug,title,kind,current_rev,created_at,updated_at) VALUES('other-doc',1,'other','Other','reference',1,'',''); INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at) SELECT 'other-rev',id,1,'Foreign','accepted','human:acme','' FROM doc WHERE slug='other';"
          )
        }
        let before = try DocVerificationPreparationTests.truth(store)
        let error = try #require(
          DocProposalServiceTests.refusal(base == "doc:rules@99" ? .notFound : .invalid) {
            _ = try DocProposalServiceTests.service(home, store).propose(
              DocProposalRequest(slug: "rules", base: base, why: "Share"), input: { "Proposal" })
          })
        #expect(error.next.first == "silta --ws 'acme' doc show 'doc:rules'")
        #expect(!error.message.contains("Foreign"))
        #expect(try DocVerificationPreparationTests.truth(store) == before)
      }
    }
    if base == "doc:rules@99" {
      withKnownIssue("SI-126/33: typed missing base must be notFound") { try check() }
    } else {
      try check()
    }
  }

  private static let retry =
    "silta --ws 'acme' doc propose 'doc:rules' -F <file> -m <why> --title <title> --about <ref>"

  private static func history(_ home: URL) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: home)
    try DocWritePolicyTests.seed(store)
    var draft = DocDraft(slug: "rules", body: "Current knowledge")
    draft.title = "Current title"
    draft.about = ["service:push"]
    _ = try DocStoreTests.accept(draft, in: store, ids: SeededIDGenerator(seed: 854))
    return store
  }
}
