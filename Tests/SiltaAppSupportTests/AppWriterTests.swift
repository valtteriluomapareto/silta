#if DEBUG
  import Foundation
  import GRDB
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  @Suite(.blockingTestWork)
  struct AppWriterTests {
    static func reader(_ scratch: URL, home: String = "silta-home") throws -> AppReader {
      try AppReader(
        home: scratch.appending(path: home), user: AppV2Fixture.user,
        now: { AppV2Fixture.now })
    }

    static func failure(_ body: () throws -> Void) throws -> AppReadError {
      var failure: AppReadError?
      do { try body() } catch let error as AppReadError { failure = error }
      return try #require(failure)
    }

    static func agent(_ reader: AppReader, _ actor: ActorID, seed: UInt64 = 5) -> TaskService {
      let clock = FakeClock(now: AppV2Fixture.now)
      return TaskService(
        environment: SiltaEnvironment(
          clock: clock, ids: SeededIDGenerator(seed: seed), git: ScriptedGitRunner(script: []),
          home: reader.environment.home,
          db: DatabaseStore(home: reader.environment.home.url, clock: clock, jitter: { 0 }),
          log: FakeLog(), actor: actor),
        workspace: "acme")
    }

    @Test func answerLandsAsTheHumanAndLeavesMyWork() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try Self.reader(scratch)
        try AppWriter(reader: reader).perform(
          .answer(task: "AC-12", question: "AC-12/1", body: "Show them under Other."),
          workspace: "acme")
        let fresh = try Self.reader(scratch)
        let posted = try #require(try fresh.task("AC-12", workspace: "acme").comments.last)
        #expect(posted.actor == "human:acme")
        #expect(posted.kind == "answer")
        #expect(posted.replyTo == "AC-12/1")
        #expect(posted.body == "Show them under Other.")
        let items = try fresh.snapshot(workspace: "acme").work.items
        #expect(!items.contains { $0.kind == "question" && $0.task == "AC-12" })
      }
    }

    @Test func commentLandsAsTheHuman() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try Self.reader(scratch)
        try AppWriter(reader: reader).perform(
          .comment(task: "AC-15", body: "Start with the empty state."), workspace: "acme")
        let posted = try #require(try reader.task("AC-15", workspace: "acme").comments.last)
        #expect(posted.actor == "human:acme")
        #expect(posted.kind == "comment")
        #expect(posted.replyTo == nil)
      }
    }

    @Test func acceptingAnAnswerClearsItAndRepeatingIsHarmless() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try Self.reader(scratch)
        let answer = try #require(
          try reader.snapshot(workspace: "acme").work.items.first { $0.kind == "answer" })
        #expect(answer.ref == "AC-14/2")
        #expect(
          answer.commands.contains { $0.hasSuffix("comment accept 'AC-14/2'") },
          "\(answer.commands)")
        let writer = AppWriter(reader: reader)
        try writer.perform(.acceptAnswer(ref: "AC-14/2"), workspace: "acme")
        #expect(
          !(try reader.snapshot(workspace: "acme").work.items.contains { $0.kind == "answer" }))
        try writer.perform(.acceptAnswer(ref: "AC-14/2"), workspace: "acme")
      }
    }

    @Test func coreRefusalsKeepTheirCodeAndWriteNothing() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try Self.reader(scratch)
        let writer = AppWriter(reader: reader)
        let before = try reader.task("AC-12", workspace: "acme").comments
        let question = try Self.failure {
          try writer.perform(.acceptAnswer(ref: "AC-12/1"), workspace: "acme")
        }
        #expect(question.kind == .other)
        #expect(question.code == .invalid)
        let missing = try Self.failure {
          try writer.perform(.comment(task: "AC-99", body: "Hello."), workspace: "acme")
        }
        #expect(missing.code == .notFound)
        #expect(try reader.task("AC-12", workspace: "acme").comments == before)
      }
    }

    @Test func onlyTheAskerOrClaimerMayAcceptAnAnswer() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try Self.reader(scratch)
        var question = CommentDraft(body: "Which endpoint?", kind: "question")
        question.recipients = ["agent:codex:fixture"]
        let asked = try Self.agent(reader, .agent(tool: "claude", session: "other"))
          .comment("AC-15", question)
        var answer = CommentDraft(body: "The paged one.", kind: "answer")
        answer.replyTo = asked.comment.ref
        let answered = try Self.agent(reader, .agent(tool: "codex", session: "fixture"), seed: 6)
          .comment("AC-15", answer)
        let before = try reader.task("AC-15", workspace: "acme").comments
        let refused = try Self.failure {
          try AppWriter(reader: reader).perform(
            .acceptAnswer(ref: answered.comment.ref), workspace: "acme")
        }
        #expect(refused.kind == .other && refused.code == .conflict)
        #expect(try reader.task("AC-15", workspace: "acme").comments == before)
      }
    }

    @Test func aSecretIsRefusedForTheHuman() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try Self.reader(scratch)
        let before = try reader.task("AC-15", workspace: "acme").comments
        let refused = try Self.failure {
          try AppWriter(reader: reader).perform(
            .comment(task: "AC-15", body: "Use sk-ant-api03-" + String(repeating: "a", count: 90)),
            workspace: "acme")
        }
        #expect(refused.code == .invalid)
        #expect(try reader.task("AC-15", workspace: "acme").comments == before)
        let log = try String(
          contentsOf: scratch.appending(path: "silta-home/log/2026-11-16.jsonl"), encoding: .utf8)
        #expect(log.contains("\"error_code\":\"invalid\"") && !log.contains("sk-ant"))
      }
    }

    @Test func aMissingStoreIsNotCreated() throws {
      try withScratchDirectory { scratch in
        let reader = try Self.reader(scratch, home: "absent")
        let refused = try Self.failure {
          try AppWriter(reader: reader).perform(
            .comment(task: "AC-15", body: "Hello."), workspace: "acme")
        }
        #expect(refused.kind == .unavailableStore, "\(refused.code) \(refused.message)")
        #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "absent").path))
      }
    }

    @Test func aWarmedWriterUsesTheReplacementAndRefusesRemoval() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let writer = AppWriter(reader: try Self.reader(scratch))
        let first = "Acme comment in the first store."
        let second = "Acme comment in the replacement."
        try writer.perform(.comment(task: "AC-15", body: first), workspace: "acme")
        let current = scratch.appending(path: "silta-home")
        let retired = scratch.appending(path: "retired")
        try FileManager.default.moveItem(at: current, to: retired)
        try AppFixtures.seed(in: scratch)
        try writer.perform(.comment(task: "AC-15", body: second), workspace: "acme")

        let old = try Self.reader(scratch, home: "retired").task("AC-15", workspace: "acme")
        let replaced = try Self.reader(scratch).task("AC-15", workspace: "acme")
        #expect(old.comments.last?.body == first)
        #expect(replaced.comments.last?.body == second)
        #expect(!replaced.comments.contains { $0.body == first })
        try FileManager.default.moveItem(at: current, to: scratch.appending(path: "removed"))
        let refused = try Self.failure {
          try writer.perform(
            .comment(task: "AC-15", body: "Would recreate the store."), workspace: "acme")
        }
        #expect(refused.kind == .unavailableStore)
        #expect(!FileManager.default.fileExists(atPath: current.path))
      }
    }

    @Test func aStoreNeedingMigrationIsLeftUnchanged() throws {
      try withScratchDirectory { scratch in
        let home = scratch.appending(path: "silta-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let path = home.appending(path: "silta.db")
        let queue = try DatabaseQueue(path: path.path)
        try StorageSchema.migrator.migrate(queue, upTo: "v1")
        try queue.close()
        let before = try Data(contentsOf: path)
        let refused = try Self.failure {
          try AppWriter(reader: try Self.reader(scratch)).perform(
            .comment(task: "AC-15", body: "Hello."), workspace: "acme")
        }
        #expect(refused.kind == .migrationRequired, "\(refused.code) \(refused.message)")
        #expect(try Data(contentsOf: path) == before)
      }
    }

    @Test func theWriterFloorRefusesAsANewerSchema() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try Self.reader(scratch)
        let queue = try DatabaseQueue(
          path: scratch.appending(path: "silta-home/silta.db").path)
        try queue.write {
          try $0.execute(sql: "UPDATE meta SET value='999' WHERE key='min_writer_version'")
        }
        try queue.close()
        let before = try reader.task("AC-15", workspace: "acme").comments
        let refused = try Self.failure {
          try AppWriter(reader: reader).perform(
            .comment(task: "AC-15", body: "Hello."), workspace: "acme")
        }
        #expect(refused.kind == .newerSchema)
        #expect(try reader.task("AC-15", workspace: "acme").comments == before)
      }
    }

    @Test func anAgentWriteBetweenTheReadAndTheWriteIsKept() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try Self.reader(scratch)
        let read = try reader.task("AC-12", workspace: "acme")
        _ = try Self.agent(reader, .agent(tool: "claude", session: "fixture")).comment(
          "AC-12", CommentDraft(body: "Still parsing."))
        try AppWriter(reader: reader).perform(
          .answer(task: "AC-12", question: "AC-12/1", body: "Other."), workspace: "acme")
        let comments = try reader.task("AC-12", workspace: "acme").comments
        #expect(comments.map(\.ref).sorted() == read.comments.map(\.ref) + ["AC-12/2", "AC-12/3"])
        let agent = comments.first { $0.ref == "AC-12/2" }
        let human = comments.first { $0.ref == "AC-12/3" }
        #expect(agent?.actor == "agent:claude:fixture" && agent?.body == "Still parsing.")
        #expect(human?.actor == "human:acme" && human?.replyTo == "AC-12/1")
      }
    }

    @Test func eachWriteLogsOneBodyFreeLine() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try Self.reader(scratch)
        let writer = AppWriter(reader: reader)
        try writer.perform(
          .answer(task: "AC-12", question: "AC-12/1", body: "Show them under Other."),
          workspace: "acme")
        #expect(throws: AppReadError.self) {
          try writer.perform(.comment(task: "AC-99", body: "Private words."), workspace: "acme")
        }
        try writer.perform(.acceptAnswer(ref: "AC-14/2"), workspace: "acme")
        let log = scratch.appending(path: "silta-home/log/2026-11-16.jsonl")
        let text = try String(contentsOf: log, encoding: .utf8)
        let lines = try text.split(separator: "\n").map {
          try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        #expect(lines.count == 3)
        #expect(
          lines.map { $0?["command"] as? String } == [
            "app answer", "app comment", "app accept-answer",
          ])
        #expect(lines.allSatisfy { $0?["actor"] as? String == "human:acme" })
        #expect(lines.allSatisfy { $0?["workspace"] as? String == "acme" })
        #expect(lines.map { $0?["exit_code"] as? Int } == [0, 2, 0])
        #expect(lines[1]?["error_code"] as? String == "not_found")
        #expect(!text.contains("Show them") && !text.contains("Private words"))
      }
    }
  }
#endif
