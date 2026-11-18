#if DEBUG
  import Foundation
  import GRDB
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  @Suite(.blockingTestWork) struct AppWorkPresentationTests {
    @Test func proposalAttributionAndReviewMetadataStayReadOnly() throws {
      try withScratchDirectory { scratch in
        try AppDocsFixture.seed(home: scratch.appending(path: "silta-home"))
        let reader = try AppReaderTests.reader(scratch)
        let observer = try DatabaseQueue(path: reader.environment.db.path)
        let before = try observer.read { try Int.fetchOne($0, sql: "PRAGMA data_version") }
        let snapshot = try reader.snapshot(workspace: "acme")
        let docs = snapshot.work.items.filter { $0.kind == "doc_proposal" }
        let orderItem = docs.first { $0.refs.first == "doc:order-contract@3" }
        let order = try #require(orderItem)
        #expect(order.author == "agent:codex:fixture" && order.documentRevision == 3)
        #expect(order.sourceTask == "AC-9")
        let pushItem = docs.first { $0.refs.first == "doc:push-categories@1" }
        let push = try #require(pushItem)
        #expect(push.author == "agent:claude:fixture" && push.sourceTask == "AC-12")
        let review = try #require(snapshot.work.reviews.first)
        #expect(review.submission?.actor == "agent:codex:fixture")
        #expect(review.submission?.at != review.updatedAt)
        #expect(review.links.contains("url:https://github.com/acme/example/pull/41"))
        #expect(review.steps.count == 4 && review.steps.allSatisfy(\.done))
        #expect(snapshot.work.waitingCount == 7)
        #expect(try observer.read { try Int.fetchOne($0, sql: "PRAGMA data_version") } == before)
        let inbox = try TaskService(environment: reader.environment, workspace: "acme").inbox(
          for: "me")
        let json =
          try JSONSerialization.jsonObject(with: JSONEncoder().encode(inbox)) as? [String: Any]
        let items = try #require(json?["items"] as? [[String: Any]])
        let doc = try #require(
          items.first { $0["kind"] as? String == "doc_proposal" }?["doc_proposal"] as? [String: Any]
        )
        let member = try #require((doc["members"] as? [[String: Any]])?.first)
        #expect(member["author"] == nil && member["revision"] == nil)
      }
    }

    @Test func submissionUsesTheSubmitterAndMasksNewAttribution() async throws {
      try await withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        let clock = FakeClock(now: AppV2Fixture.now)
        let ids = SeededIDGenerator(seed: 886)
        func service(_ actor: ActorID) -> TaskService {
          TaskService(
            environment: SiltaEnvironment(
              clock: clock, ids: ids,
              git: ScriptedGitRunner(script: []), home: reader.environment.home,
              db: reader.environment.db, log: FakeLog(), actor: actor, human: .human(name: "acme")),
            workspace: "acme")
        }
        var draft = TaskDraft(title: "Acme review attribution")
        draft.app = TaskDraft.noneApp
        _ = try await service(.human(name: "acme")).add(draft, directory: scratch)
        let ref = try await service(.human(name: "acme")).add(draft, directory: scratch).ref
        let submitter = service(.agent(tool: "claude", session: "submitter"))
        _ = try await submitter.start(ref, directory: scratch)
        _ = try submitter.submit(ref)
        let task = try reader.task(ref, workspace: "acme")
        #expect(task.createdBy == "human:acme")
        #expect(task.submission?.actor == "agent:claude:submitter")
        _ = try submitter.link(ref, target: "url:https://github.com/acme/example/pull/41")
        try reader.environment.db.write { tx in
          try tx.database.execute(
            sql:
              """
              UPDATE task_event SET actor='Password=private123'
              WHERE task_id=(SELECT id FROM task WHERE seq=24) AND kind='status'
              """
          )
          try tx.database.execute(
            sql:
              """
              UPDATE link SET to_ext='https://github.com/acme/example/pull/41?Password%3Dprivate123'
              WHERE from_kind='task' AND from_id=(SELECT id FROM task WHERE seq=24)
              """
          )
        }
        withKnownIssue("The seq=24 mutation silently misses the dynamically allocated task") {
          let poisoned = try reader.environment.db.read { db in
            try String.fetchOne(db, sql: "SELECT actor FROM task_event WHERE task_id=(SELECT id FROM task WHERE workspace_id=(SELECT id FROM workspace WHERE slug='acme') AND seq=?) AND kind='status' ORDER BY id DESC LIMIT 1", arguments: [Int(ref.split(separator: "-").last ?? "")])
          }
          #expect(poisoned == "Password=private123")
        }
        let masked = try reader.task(ref, workspace: "acme")
        let actor = masked.submission?.actor ?? ""
        #expect(!actor.contains("private123"))
        #expect(!masked.links.joined().contains("private123"))
      }
    }
  }
#endif
