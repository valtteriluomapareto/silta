import Foundation
import GRDB
@testable import SiltaAppSupport
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct AppReaderTests {
  static func reader(_ scratch: URL) throws -> AppReader {
    try AppReader(home: scratch.appending(path: "silta-home"), user: "acme", now: { AppV2Fixture.now })
  }

  @Test func seedIsACompleteCoreFixture() throws {
    try withScratchDirectory { scratch in
      try AppFixtures.seed(in: scratch)
      let service = TaskService(environment: try Self.reader(scratch).environment, workspace: "acme")
      var filter = TaskFilter()
      filter.proposed = true
      let tasks = try service.list(filter)
      #expect(tasks.count == 13)
      #expect(tasks.filter { $0.status == "todo" }.count == 4)
      #expect(tasks.filter { $0.status == "doing" }.count == 2)
      #expect(tasks.filter { $0.status == "review" }.count == 1)
      #expect(tasks.filter { $0.status == "proposed" }.count == 3)
      #expect(try service.inbox(for: "me").items.count == 4)
    }
  }

  @Test func reconcilesWorkspaceBoardAndHumanAttention() throws {
    try withScratchDirectory { scratch in
      try AppFixtures.seed(in: scratch)
      let reader = try Self.reader(scratch)
      withKnownIssue("Read projections are not implemented yet.") {
        #expect(try reader.workspaces() == [AppWorkspace(slug: "acme", name: "Acme")])
        let snapshot = try reader.snapshot(workspace: "acme")
        #expect(snapshot.board.todo.count == 4)
        #expect(snapshot.board.doing.count == 2)
        #expect(snapshot.board.review.map(\.ref) == ["AC-9"])
        #expect(snapshot.board.doneThisWeek.count == 3)
        #expect(snapshot.board.proposedCount == 3)
        #expect(snapshot.board.appOpenCounts == ["acme-mobile": 3, "acme-backend": 3, "acme-web": 1])
        #expect(snapshot.work.waitingCount == 5)
        #expect(snapshot.work.items.first?.commands.first?.contains("--kind answer") == true)
        #expect(snapshot.work.items.allSatisfy { !$0.commands.joined().contains("--approved") })
      }
    }
  }

  @Test func detailUsesCoreChecklistAndDiscussion() throws {
    try withScratchDirectory { scratch in
      try AppFixtures.seed(in: scratch)
      let reader = try Self.reader(scratch)
      let env = reader.environment
      let owner = SiltaEnvironment(
        clock: env.clock, ids: env.ids, git: env.git, home: env.home, db: env.db,
        log: env.log, actor: .agent(tool: "claude", session: "fixture"), human: env.human)
      _ = try TaskService(environment: owner, workspace: "acme").plan(
        "AC-12", text: "- [x] First\n  - [ ] Nested\n```\n- [ ] Example\n```\n1. [ ] Second\n")
      withKnownIssue("Task detail is not implemented yet.") {
        let task = try reader.task("AC-12", workspace: "acme")
        #expect(task.steps.map(\.title) == ["First", "Second"])
        #expect(task.steps.map(\.done) == [true, false])
        #expect(task.claimedBy == "agent:claude:fixture")
        #expect(task.comments.map(\.ref) == ["AC-12/1"])
        #expect(task.comments.first?.kind == "question")
      }
    }
  }

  @Test func separateQuestionsAndReviewOnTheSameTaskRemainDistinct() throws {
    try withScratchDirectory { scratch in
      try AppFixtures.seed(in: scratch)
      let reader = try Self.reader(scratch)
      let service = Self.asker(reader.environment)
      for ref in ["AC-12", "AC-12", "AC-9"] {
        var draft = CommentDraft(body: "Which API should Acme use?", kind: "question")
        draft.recipients = ["human:acme"]
        _ = try service.comment(ref, draft)
      }
      withKnownIssue("Attention projection is not implemented yet.") {
        let work = try reader.snapshot(workspace: "acme").work
        #expect(work.items.filter { $0.kind == "question" }.count == 4)
        #expect(Set(work.items.filter { $0.kind == "question" }.compactMap(\.ref)).count == 4)
        #expect(work.reviews.map(\.ref) == ["AC-9"])
        #expect(work.waitingCount == 8)
      }
    }
  }

  @Test func currentInboxKeepsItsCapAndProposalAgeBoundary() throws {
    try withScratchDirectory { scratch in
      try AppFixtures.seed(in: scratch)
      let reader = try Self.reader(scratch)
      try reader.environment.db.write { tx in
        let cutoff = AppV2Fixture.now.addingTimeInterval(-14 * 86_400)
        for (ref, offset) in [(21, -0.001), (22, 0.0), (23, 0.001)] {
          try tx.database.execute(
            sql: "UPDATE task SET created_at=? WHERE seq=?",
            arguments: [TaskService.timestamp(cutoff.addingTimeInterval(offset)), ref])
        }
      }
      let service = Self.asker(reader.environment)
      for _ in 0..<13 {
        var draft = CommentDraft(body: "Which Acme API version?", kind: "question")
        draft.recipients = ["human:acme"]
        _ = try service.comment("AC-12", draft)
      }
      withKnownIssue("Current capped inbox projection is not implemented yet.") {
        let work = try reader.snapshot(workspace: "acme").work
        #expect(work.items.count == 12)
        #expect(work.remaining == 3)
        #expect(work.waitingCount == 16)
        #expect(work.moreCommand != nil)
      }
    }
  }

  @Test func completionWeekUsesMondayUTCAndClosedTime() throws {
    try withScratchDirectory { scratch in
      try AppFixtures.seed(in: scratch)
      let reader = try Self.reader(scratch)
      var calendar = Calendar(identifier: .iso8601)
      calendar.timeZone = .gmt
      let week = try #require(calendar.dateInterval(of: .weekOfYear, for: AppV2Fixture.now))
      try reader.environment.db.write { tx in
        for (ref, date) in [(6, week.start.addingTimeInterval(-0.001)), (7, week.start),
          (8, AppV2Fixture.now.addingTimeInterval(1))]
        {
          try tx.database.execute(
            sql: "UPDATE task SET closed_at=?,updated_at=? WHERE seq=?",
            arguments: [TaskService.timestamp(date), TaskService.timestamp(AppV2Fixture.now), ref])
        }
      }
      withKnownIssue("Completion-week projection is not implemented yet.") {
        let snapshot = try reader.snapshot(workspace: "acme")
        #expect(snapshot.board.doneThisWeek.map(\.ref) == ["AC-7"])
      }
    }
  }

  @Test func matchesCLIValuesAndReadsNeverChangeOwnedData() throws {
    try withScratchDirectory { scratch in
      try AppFixtures.seed(in: scratch)
      let reader = try Self.reader(scratch)
      let before = try Data(contentsOf: scratch.appending(path: "silta-home/silta.db"))
      let listed = try Self.cli(["task", "ls", "--proposed", "--json"], scratch)
      let tasks = try #require(listed["tasks"] as? [[String: Any]])
      let shown = try Self.cli(["task", "show", "AC-12", "--json"], scratch)
      let inbox = try Self.cli(["inbox", "--for", "me", "--json"], scratch)
      let items = try #require(inbox["items"] as? [[String: Any]])
      withKnownIssue("CLI agreement projections are not implemented yet.") {
        let snapshot = try reader.snapshot(workspace: "acme")
        let board = snapshot.board
        #expect(Set((board.todo + board.doing + board.review).map(\.ref))
          == Set(tasks.filter { ["todo", "doing", "review"].contains($0["status"] as? String ?? "") }
            .compactMap { $0["ref"] as? String }))
        let detail = try reader.task("AC-12", workspace: "acme")
        #expect(detail.title == shown["title"] as? String)
        #expect(detail.plan == shown["plan"] as? String)
        #expect(snapshot.work.items.compactMap(\.ref) == items.compactMap { $0["ref"] as? String })
      }
      #expect(try Data(contentsOf: scratch.appending(path: "silta-home/silta.db")) == before)
    }
  }

  @Test func blockedTasksStayVisibleInTodo() throws {
    try withScratchDirectory { scratch in
      try AppFixtures.seed(in: scratch)
      let reader = try Self.reader(scratch)
      var block = TaskBlock(why: "Needs the Acme API cleanup.")
      block.on = ["AC-18"]
      _ = try TaskService(environment: reader.environment, workspace: "acme").block("AC-17", block)
      withKnownIssue("Blocked task projection is not implemented yet.") {
        let board = try reader.snapshot(workspace: "acme").board
        #expect(board.todo.count == 4)
        #expect(board.todo.first { $0.ref == "AC-17" }?.status == "blocked")
        #expect(board.appOpenCounts["acme-mobile"] == 3)
      }
    }
  }

  @Test func groupedAttentionPreservesEveryDisplayRef() throws {
    try withScratchDirectory { scratch in
      try AppFixtures.seed(in: scratch)
      let reader = try Self.reader(scratch)
      let service = TaskService(environment: reader.environment, workspace: "acme")
      var block = TaskBlock(why: "Acme must confirm the API.")
      block.on = ["ext:acme-team"]
      block.followUp = "0d"
      for ref in ["AC-15", "AC-17"] { _ = try service.block(ref, block) }
      let expected = ["AC-15", "AC-17"]
      #expect(try service.inbox(for: "me").items.first { $0.kind == "due" }?.tasks?.map(\.ref) == expected)
      withKnownIssue("Grouped attention projection is not implemented yet.") {
        let work = try reader.snapshot(workspace: "acme").work
        let due = try #require(work.items.first { $0.kind == "due" })
        #expect(due.refs == expected)
      }
    }
  }

  @Test func missingAndNewerStoresFailWithoutInitializationOrMigration() throws {
    try withScratchDirectory { scratch in
      let reader = try Self.reader(scratch)
      withKnownIssue("Reader schema preflight is not implemented yet.") {
        var failure: AppReadError?
        do { _ = try reader.workspaces() } catch let error as AppReadError { failure = error }
        #expect(failure?.kind == .unavailableStore)
      }
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home").path))
      try AppFixtures.seed(in: scratch)
      try reader.environment.db.write { tx in
        try tx.database.execute(sql: "INSERT INTO grdb_migrations VALUES('future-app-schema')")
      }
      let before = try Data(contentsOf: scratch.appending(path: "silta-home/silta.db"))
      withKnownIssue("Reader schema preflight is not implemented yet.") {
        var failure: AppReadError?
        do { _ = try reader.snapshot(workspace: "acme") } catch let error as AppReadError { failure = error }
        #expect(failure?.kind == .newerSchema)
      }
      #expect(try Data(contentsOf: scratch.appending(path: "silta-home/silta.db")) == before)
    }
  }

  @Test func seedIsRepeatableAndRefusesExistingData() throws {
    try withScratchDirectory { scratch in
      try AppFixtures.seed(in: scratch)
      let second = scratch.appending(path: "second")
      try AppFixtures.seed(in: second)
      func values(_ base: URL) throws -> [String] {
        try Self.reader(base).environment.db.read {
          try String.fetchAll($0, sql: "SELECT uid || ':' || title || ':' || created_at FROM task ORDER BY seq")
        }
      }
      #expect(try values(scratch) == values(second))
      #expect(throws: WorkspaceError.self) { try AppFixtures.seed(in: scratch) }
    }
  }

  private static func asker(_ env: SiltaEnvironment) -> TaskService {
    TaskService(environment: SiltaEnvironment(
      clock: env.clock, ids: SeededIDGenerator(seed: 951), git: env.git, home: env.home,
      db: env.db, log: env.log, actor: .agent(tool: "codex", session: "asker"), human: env.human),
      workspace: "acme")
  }

  private static func cli(_ arguments: [String], _ scratch: URL) throws -> [String: Any] {
    let result = try SiltaBinary.run(["--ws", "acme"] + arguments, in: scratch, environment: [
      "USER": "acme", "SILTA_ACTOR": "agent:codex:reader", "SILTA_NOW": "2026-11-16T12:00:00.000Z",
    ])
    try #require(result.termination == .exit(0))
    let root = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    return try #require(root["data"] as? [String: Any])
  }
}
