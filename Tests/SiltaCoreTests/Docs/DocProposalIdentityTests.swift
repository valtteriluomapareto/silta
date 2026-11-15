import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposalIdentityTests {
  @Test(arguments: ["app", "topic", "service", "edge"])
  func pendingTargetsFollowRenameAndRefuseReplacement(kind: String) throws {
    withKnownIssue("SI-138: pending attachment filters use stored target UIDs") {
      try withScratchDirectory { home in
        let store = try AcmeDocAttachments.make(in: home)
        let old = [
          "app": "app:api", "topic": "topic:messaging", "service": "service:push",
          "edge": "edge:api/service:push/sdk",
        ]
        let renamed = [
          "app": "app:renamed", "topic": "topic:renamed",
          "service": "service:renamed", "edge": "edge:api/service:push/renamed",
        ]
        let field = kind == "edge" ? "kind" : "slug"
        let name = ["app": "api", "topic": "messaging", "service": "push", "edge": "sdk"]
        let oldRef = try #require(old[kind])
        let newRef = try #require(renamed[kind])
        let request = DocProposalRequest(
          slug: "rules", title: "Rules", about: [oldRef], why: "Share")
        _ = try DocProposalServiceTests.service(home, store).propose(request, input: { "Body" })
        let service = DocService(workspace: "acme", store: store)
        try store.write { try $0.database.execute(sql: "UPDATE \(kind) SET \(field)='renamed'") }
        #expect(
          try service.list(about: newRef).entries.map(\.ref) == ["doc:rules@1"])
        try store.write {
          try $0.database.execute(
            sql: "UPDATE \(kind) SET \(field)=?,uid='replacement'", arguments: [name[kind]])
        }
        #expect(try service.list(about: oldRef).entries.isEmpty)
        #expect(try service.list().entries.map(\.ref) == ["doc:rules@1"])
      }
    }
  }

  @Test(arguments: [false, true])
  func acceptedAProposedBFilterIsolation(unknownLegacy: Bool) throws {
    withKnownIssue("SI-138: pending rows never borrow accepted attachments") {
      try withScratchDirectory { home in
        let store = try AcmeDocAttachments.make(in: home)
        var draft = DocDraft(slug: "rules", body: "Accepted")
        draft.title = "Rules"
        draft.about = ["app:api"]
        _ = try DocStoreTests.accept(draft, in: store, ids: SeededIDGenerator(seed: 82))
        _ = try DocProposalServiceTests.service(home, store).propose(
          DocProposalServiceTests.request(), input: { "Proposed" })
        if unknownLegacy {
          try store.write {
            if try $0.database.columns(in: "doc_rev").contains(where: { $0.name == "about_targets" }
            ) {
              try $0.database.execute(sql: "UPDATE doc_rev SET about_targets=NULL WHERE rev=2")
            }
          }
        }
        let service = DocService(workspace: "acme", store: store)
        #expect(try service.list(about: "app:api").entries.map(\.ref) == ["doc:rules@1"])
        #expect(
          try service.list(about: "service:push").entries.map(\.ref)
            == (unknownLegacy ? [] : ["doc:rules@2"]))
        #expect(try service.list().entries.count == 2)
      }
    }
  }

  @Test(arguments: [false, true])
  func invalidTargetUIDRaceKeepsHumanBackupRecovery(nul: Bool) throws {
    withKnownIssue("SI-138: preserve target UID admission through private recheck") {
      try withScratchDirectory { home in
        let store = try AcmeDocAttachments.make(in: home)
        let uid = try #require(
          store.read { try String.fetchOne($0, sql: "SELECT uid FROM service") })
        var committed: [[String]] = []
        var failure: (any CodedError)?
        do {
          _ = try DocProposalServiceTests.service(home, store).propose(
            DocProposalServiceTests.request()
          ) {
            try store.write {
              try $0.database.execute(
                sql: "UPDATE service SET uid=CAST(? AS TEXT)",
                arguments: [Data((nul ? uid + "\u{0}suffix" : "\u{212a}").utf8)])
            }
            committed = try DocVerificationPreparationTests.truth(store)
            return "Body"
          }
        } catch let error as any CodedError { failure = error }
        DocStoredIdentityTests.expectBackup(failure)
        #expect(!committed.isEmpty)
        #expect(try DocVerificationPreparationTests.truth(store) == committed)
      }
    }
  }
}
