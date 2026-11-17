import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposalAttentionTests {
  @Test(arguments: [false, true], [false, true])
  func staleEvidenceAndGuidanceUseTheSnapshotAndActualCaller(human: Bool, advanced: Bool) throws {
    withKnownIssue {
      try withScratchDirectory { home in
        let (store, service, older, latest) = try fixture(home, human: human, advanced: advanced)
        let before = try DocVerificationPreparationTests.truth(store)
        let inbox = try service.inbox(for: "human:acme")
        let item = try #require(inbox.items.first)
        let group = try payload(inbox)
        let members = try #require(group["members"] as? [[String: Any]])
        #expect(members.count == 2)
        for member in members {
          let ref = try #require(member["ref"] as? String)
          let stale = advanced && ref == older
          #expect(member["stale_base"] as? Bool == stale)
          #expect((member["summary"] as? String ?? "").contains("stale base") == stale)
          #expect(item.next.contains { $0.contains("doc triage --reject " + shellWord(ref)) })
          #expect(
            item.next.contains { $0.contains("doc triage --accept " + shellWord(ref)) } == !stale)
        }
        let actions = item.next.filter { $0.contains("doc triage") }
        #expect(actions.count == (human ? (advanced ? 3 : 4) : 2))
        #expect(actions.allSatisfy { $0.utf8.count <= 512 })
        if human {
          #expect(actions.allSatisfy { !$0.contains("ask human:") && !$0.contains("--approved") })
          let report = try store.read {
            try BriefDocProposalTests().makeReport(service, budget: 1024, in: $0)
          }
          #expect(report.text.contains("doc triage --accept " + shellWord(latest)))
          #expect(report.text.contains("more: silta --ws 'acme' inbox\n"))
          #expect(report.text.count <= 4096)
        } else {
          #expect(actions.allSatisfy { $0.hasPrefix("ask human:") })
          #expect(actions.allSatisfy { $0.contains("--approved \"<the human's words>\"") })
        }
        #expect(try DocVerificationPreparationTests.truth(store) == before)
      }
    }
  }

  @Test func nilAndUnavailableBasesKeepDistinctDecisionRecovery() throws {
    withKnownIssue {
      try withScratchDirectory { home in
        let store = try AcmeDocAttachments.make(in: home)
        let env = try DocTriageServiceTests.environment(home, store, human: true)
        let fresh = try DocTriageServiceTests.propose(env, about: "topic:messaging")
        let service = TaskService(environment: env, workspace: "acme")
        let first = try service.inbox()
        let group = try payload(first)
        let member = try #require((group["members"] as? [[String: Any]])?.first)
        #expect(member["stale_base"] as? Bool == false)
        #expect(
          first.items[0].next.contains { $0.contains("doc triage --accept " + shellWord(fresh)) })
        let (other, otherService, older, _) = try fixture(
          home.appending(path: "missing"), human: true, advanced: true)
        try other.write {
          try $0.database.execute(sql: "UPDATE doc_rev SET base_rev=99 WHERE rev=2")
        }
        let before = try DocVerificationPreparationTests.truth(other)
        let missing = try otherService.inbox()
        let missingGroup = try payload(missing)
        let row = try #require(
          (missingGroup["members"] as? [[String: Any]])?.first {
            $0["ref"] as? String == older
          })
        #expect(row["stale_base"] as? Bool == true)
        #expect((row["summary"] as? String ?? "").contains("recorded base unavailable"))
        #expect((row["read"] as? String)?.hasSuffix(" --diff") == false)
        #expect(
          !missing.items[0].next.contains { $0.contains("doc triage --accept " + shellWord(older)) }
        )
        #expect(
          missing.items[0].next.contains { $0.contains("doc triage --reject " + shellWord(older)) })
        #expect(try DocVerificationPreparationTests.truth(other) == before)
      }
    }
  }

  @Test func unsafeIdentitiesKeepProtectedReadHubs() throws {
    try withScratchDirectory { home in
      let (store, service, _, _) = try fixture(home, human: false, advanced: false)
      let secret = "AKIA" + String(repeating: "A", count: 16)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET slug=?", arguments: [secret])
      }
      let before = try DocVerificationPreparationTests.truth(store)
      let inbox = try service.inbox(for: "human:acme")
      #expect(inbox.items[0].next == ["silta --ws 'acme' doc ls --archived"])
      #expect(!String(decoding: try JSONEncoder().encode(inbox), as: UTF8.self).contains(secret))
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  private func fixture(_ home: URL, human: Bool, advanced: Bool) throws
    -> (DatabaseStore, TaskService, String, String)
  {
    let store = try AcmeDocAttachments.make(in: home)
    let env = try DocTriageServiceTests.environment(home, store, human: human)
    var draft = DocDraft(slug: "rules", body: "Accepted Acme knowledge.")
    draft.title = "Rules"
    draft.about = ["topic:messaging"]
    _ = try DocStoreTests.accept(draft, in: store, ids: env.ids)
    let older = try DocTriageServiceTests.propose(
      env, about: "topic:messaging", body: "First proposed Acme knowledge.")
    if advanced {
      _ = try DocStoreTests.accept(
        DocDraft(slug: "rules", body: "Updated accepted Acme knowledge."), in: store, ids: env.ids)
    }
    let latest = try DocTriageServiceTests.propose(
      env, about: "topic:messaging", body: "Latest proposed Acme knowledge.")
    return (store, TaskService(environment: env, workspace: "acme"), older, latest)
  }

  private func payload(_ result: InboxResult) throws -> [String: Any] {
    try #require(
      try DocInboxIntegrationTests().items(result).first?["doc_proposal"] as? [String: Any])
  }
}
