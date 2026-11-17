#if DEBUG
  import Foundation
  import GRDB
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  @Suite(.blockingTestWork, .timeLimit(.minutes(1)))
  struct AppCommandTests {
    @Test func templatesKeepChoicesAndBodiesUnfilled() throws {
      do {
        try withScratchDirectory { scratch in
          try AppFixtures.seed(in: scratch)
          let reader = try AppReaderTests.reader(scratch)
          let snapshot = try reader.snapshot(workspace: "acme")
          let question = try #require(snapshot.work.items.first { $0.kind == "question" })
          let command = try #require(reader.commands(for: question, workspace: "acme").first)
          #expect(
            command.text.hasSuffix("comment 'AC-12' --kind answer --reply-to 'AC-12/1' -m \"\""))
          let proposal = try #require(snapshot.work.items.first { $0.kind == "proposal" })
          let choices = reader.commands(for: proposal, workspace: "acme")
          #expect(choices.contains { $0.text.hasSuffix("task triage --accept REFS") })
          #expect(choices.contains { $0.text.hasSuffix("task triage --help") })
          let review = try #require(snapshot.work.reviews.first)
          let reads = reader.commands(forReview: review, workspace: "acme")
          #expect(reads.first?.text.hasSuffix("task show 'AC-9' --timeline") == true)
          for value in [command] + choices + reads {
            #expect(!value.text.contains("--drop") && !value.text.contains("--reject"))
            #expect(!value.text.contains(" -F ") && !value.text.contains(" task done "))
            #expect(!value.text.contains("<") && !value.text.contains("--approved"))
          }
          #expect(reader.inboxCommand(workspace: "acme").text.hasSuffix("inbox --for me --all"))
        }
      }
    }

    @Test func answerEligibilityAndGroupedRefsStayExplicit() throws {
      do {
        try withScratchDirectory { scratch in
          let reader = try AppReaderTests.reader(scratch)
          let accept = "silta --ws 'acme' comment accept 'AC-12/2'"
          let eligible = item(kind: "answer", commands: [accept])
          #expect(
            reader.commands(for: eligible, workspace: "acme").first?.text.hasSuffix(accept) == true)
          let ineligible = item(kind: "answer", commands: ["silta task show AC-12"])
          #expect(
            reader.commands(for: ineligible, workspace: "acme").allSatisfy {
              !$0.text.contains("comment accept")
            })
          let grouped = item(kind: "due", refs: ["AC-15", "AC-17"], commands: ["touch escaped"])
          let reads = reader.commands(for: grouped, workspace: "acme").map(\.text)
          #expect(reads.count == 2)
          #expect(reads.first?.hasSuffix("task show 'AC-15' --timeline") == true)
          #expect(reads.last?.hasSuffix("task show 'AC-17' --timeline") == true)
          #expect(reads.allSatisfy { !$0.contains("touch") })
          #expect(
            reader.commands(
              for: item(kind: "doc_proposal", refs: [], commands: ["touch escaped"]),
              workspace: "acme"
            ).isEmpty)
        }
      }
    }

    @Test func realHumanCommandsRefuseUnfilledInputsAndAcceptFilledOnes() throws {
      do {
        try withScratchDirectory { scratch in
          try AppFixtures.seed(in: scratch)
          let reader = try AppReaderTests.reader(scratch)
          let snapshot = try reader.snapshot(workspace: "acme")
          let observer = try DatabaseQueue(path: reader.environment.db.path)
          let before = try version(observer)
          let question = try #require(snapshot.work.items.first { $0.kind == "question" })
          let answer = try #require(reader.commands(for: question, workspace: "acme").first).text
          let refused = try run(answer, scratch)
          #expect(
            refused.stdout.contains("Comment body required; use -m or -F. [invalid]"), "\(refused)")
          #expect(try version(observer) == before)
          let proposal = try #require(snapshot.work.items.first { $0.kind == "proposal" })
          let accept = try #require(reader.commands(for: proposal, workspace: "acme").first).text
          let invalid = try run(accept, scratch)
          #expect(invalid.stdout.contains("REFS: invalid task reference. [invalid]"), "\(invalid)")
          #expect(try version(observer) == before)
          let posted = try run(
            answer.replacingOccurrences(
              of: "-m \"\"", with: "-m 'Show unknown categories as Other.'"), scratch)
          #expect(posted.termination == .exit(0), "\(posted)")
          let task = try reader.task("AC-12", workspace: "acme")
          #expect(task.comments.last?.actor == "human:acme")
          #expect(task.comments.last?.replyTo == "AC-12/1")
          let accepted = try run(accept.replacingOccurrences(of: "REFS", with: "AC-21"), scratch)
          #expect(accepted.termination == .exit(0), "\(accepted)")
          #expect(try reader.task("AC-21", workspace: "acme").status == "todo")
          #expect(try version(observer) != before)
        }
      }
    }

    @Test func shellUsesLiteralSelectedHomeAndLeavesDefaultAlone() throws {
      do {
        try withScratchDirectory { scratch in
          try AppFixtures.seed(in: scratch)
          let selected = scratch.appending(path: "Acme's $(touch escaped); home")
          try AppV2Fixture.seed(home: selected)
          let reader = try AppReader(home: selected, user: "acme", now: { AppV2Fixture.now })
          let defaultReader = try AppReaderTests.reader(scratch)
          let observer = try DatabaseQueue(path: defaultReader.environment.db.path)
          let initial = try version(observer)
          let question = try #require(
            try reader.snapshot(workspace: "acme").work.items.first { $0.kind == "question" })
          let command = try #require(reader.commands(for: question, workspace: "acme").first).text
            .replacingOccurrences(of: "-m \"\"", with: "-m 'Use the selected Acme home.'")
          let result = try run(command, scratch)
          #expect(result.termination == .exit(0), "\(result)")
          #expect(try reader.task("AC-12", workspace: "acme").comments.count == 2)
          #expect(try defaultReader.task("AC-12", workspace: "acme").comments.count == 1)
          #expect(try version(observer) == initial)
          #expect(
            !FileManager.default.fileExists(atPath: scratch.appending(path: "work/escaped").path))
        }
      }
    }

    @Test func documentAttentionNeverBecomesATaskRead() throws {
      let reader = try AppReader(home: URL(filePath: "/private/tmp/acme-unused"), user: "acme")
      let document = AppAttention(
        kind: "doc_proposal", ref: "doc:rules@2", refs: ["doc:rules@2"],
        task: nil, title: nil, author: nil, body: nil, createdAt: nil,
        commands: ["silta doc diff 'doc:rules@2'"])
      do {
        #expect(reader.commands(for: document, workspace: "acme").isEmpty)
      }
    }

    private func item(kind: String, refs: [String] = ["AC-12"], commands: [String]) -> AppAttention
    {
      AppAttention(
        kind: kind, ref: "AC-12/2", refs: refs, task: refs.first,
        title: nil, author: nil, body: nil, createdAt: nil, commands: commands)
    }

    private func run(_ command: String, _ scratch: URL) throws -> CLIResult {
      let binary = try SiltaBinary.url()
      return try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/script"),
        ["-q", "/dev/null", "/bin/sh", "-c", command], in: scratch,
        environment: [
          "USER": "acme", "SILTA_ACTOR": "human:acme",
          "SILTA_NOW": "2026-11-16T12:00:00.000Z",
          "PATH": binary.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin",
        ])
    }

    private func version(_ queue: DatabaseQueue) throws -> Int {
      try queue.read { db in
        let value = try Int.fetchOne(db, sql: "PRAGMA data_version")
        return try #require(value)
      }
    }
  }
#endif
