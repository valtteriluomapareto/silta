import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct InboxCorrectionTests {
  static func service(_ home: URL, _ actor: ActorID, _ clock: FakeClock) throws -> TaskService {
    TaskService(environment: try TaskServiceTests.environment(home, actor: actor, clock: clock))
  }

  static func post(_ service: TaskService, kind: String, to: [String] = [], reply: String? = nil)
    throws
  {
    var draft = CommentDraft(body: "Acme answer", kind: kind)
    draft.recipients = to
    draft.replyTo = reply
    _ = try service.comment("AC-1", draft)
  }

  @Test func claimerCannotAcceptOwnAnswerToHumanQuestion() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock)
      let owner = TaskService(environment: env)
      let human = try Self.service(home, .human(name: "acme"), clock)
      try Self.post(human, kind: "question", to: [env.actor.description])
      clock.advance(milliseconds: 1)
      try Self.post(owner, kind: "answer", reply: "AC-1/1")
      let before = try CommentLifecycleTests.snapshot(env)
      let items = try owner.inbox().items
      let acceptance = Result { try owner.acceptComment("AC-1/2") }
      let after = try CommentLifecycleTests.snapshot(env)
      #expect(items.isEmpty)
      if case .success = acceptance { Issue.record("Self-acceptance succeeded") }
      if case .failure(let error) = acceptance { #expect(error is CommentError) }
      #expect(after == before)
    }
  }

  @Test func strangersReadAndRelayersMustAskHuman() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock),
        owner = TaskService(environment: env)
      let relayer = try Self.service(home, .agent(tool: "claude", session: "relay"), clock)
      let stranger = try Self.service(home, .agent(tool: "codex", session: "stranger"), clock)
      try Self.post(owner, kind: "question", to: ["human:acme"])
      try Self.post(relayer, kind: "answer", reply: "AC-1/1")
      let own = try relayer.inbox(for: "human:acme").items
      let foreign = try stranger.inbox(for: "human:acme").items
      let agent = try relayer.inbox(for: env.actor.description).items
      #expect(foreign.first?.next == ["silta --ws 'acme' task show 'AC-1' --timeline"])
      #expect(agent.last?.next == ["silta --ws 'acme' task show 'AC-1' --timeline"])
      #expect(own.first?.next.first?.hasPrefix("ask human:") == true)
      #expect(
        !own.flatMap(\.next).contains {
          $0.contains("--kind answer") || $0.hasPrefix("silta --ws 'acme' comment resolve")
        })
      try Self.post(owner, kind: "question", to: ["agent:claude:addressee"])
      try Self.post(relayer, kind: "answer", reply: "AC-1/3")
      let otherAgent = try relayer.inbox(for: "agent:claude:addressee").items
      #expect(otherAgent.first?.next == ["silta --ws 'acme' task show 'AC-1' --timeline"])
    }
  }

  @Test func askerOnlyAndSuccessorOnlyHaveIndependentAcceptActions() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock),
        owner = TaskService(environment: env)
      let human = try Self.service(home, .human(name: "acme"), clock)
      let responder = try Self.service(home, .agent(tool: "claude", session: "answerer"), clock)
      try Self.post(human, kind: "question", to: ["agent:claude:answerer"])
      try Self.post(responder, kind: "answer", reply: "AC-1/1")
      #expect(try human.inbox().items.first?.next == ["silta --ws 'acme' comment accept 'AC-1/2'"])
      _ = try owner.comment("AC-1", CommentDraft(body: "Continue", kind: "handoff"))
      let successor = try Self.service(home, .agent(tool: "codex", session: "successor"), clock)
      _ = try await successor.start("AC-1", directory: home)
      #expect(
        try successor.inbox().items.first?.next == ["silta --ws 'acme' comment accept 'AC-1/2'"])
    }
  }

  @Test(arguments: ["```", "~~~"])
  func unterminatedFenceHidesNothing(marker: String) async throws {
    try await withScratchDirectory { home in
      let owner = TaskService(environment: try await CommentTests.setup(home))
      let body = marker + "\n@human:hidden\nAsk @agent:claude:reader"
      let post = try owner.comment("AC-1", CommentDraft(body: body, kind: "question")).comment
      let refs = try owner.inbox(for: "agent:claude:reader").items.map(\.ref)
      #expect(post.mentions == ["agent:claude:reader", "human:hidden"])
      #expect(refs == ["AC-1/1"])
    }
  }

  @Test func displayedResolvedHandoffIsNotHiddenHistory() async throws {
    try await withScratchDirectory { home in
      let owner = TaskService(environment: try await CommentTests.setup(home))
      _ = try owner.comment("AC-1", CommentDraft(body: "Continue", kind: "handoff"))
      _ = try owner.updateComments(["AC-1/1"], action: .resolve)
      let shown = try owner.show("AC-1")
      #expect(shown.comments?.first?.ref == "AC-1/1")
      #expect((shown.resolvedThreads ?? 0) == 0)
      _ = try owner.comment("AC-1", CommentDraft(body: "Hidden"))
      _ = try owner.updateComments(["AC-1/2"], action: .resolve)
      let hidden = try owner.show("AC-1").resolvedThreads
      #expect(hidden == 1)
    }
  }

  @Test func attentionReadsUncappedInsideSuppliedSnapshot() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home), owner = TaskService(environment: env)
      for _ in 0..<13 { try Self.post(owner, kind: "question", to: ["human:acme"]) }
      let before = try CommentLifecycleTests.snapshot(env)
      let attention = try env.db.read { db in
        try TaskService.attention(for: .human(name: "acme"), workspaceID: 1, in: db)
      }
      #expect(attention.count == 13)
      #expect(attention.first?.post.ref == "AC-1/1")
      #expect(attention.first?.task.ref == "AC-1")
      #expect(try CommentLifecycleTests.snapshot(env) == before)
    }
  }
}
