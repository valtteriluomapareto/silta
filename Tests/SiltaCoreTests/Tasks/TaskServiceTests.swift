import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskServiceTests {
  static let now = Date(timeIntervalSince1970: 1_700_000_000)

  static let agent = ActorID.agent(tool: "codex", session: "acme")

  static func environment(
    _ home: URL, actor: ActorID = agent, clock: FakeClock = FakeClock(now: now),
    git: any GitRunner = ScriptedGitRunner(script: [])
  ) throws -> SiltaEnvironment {
    let location = try SiltaHome.resolve(environment: ["SILTA_HOME": home.path])
    return SiltaEnvironment(
      clock: clock,
      ids: SeededIDGenerator(seed: actor.description.utf8.reduce(0) { $0 + UInt64($1) }), git: git,
      home: location,
      db: DatabaseStore(home: home, clock: clock, jitter: { 0 }), log: FakeLog(), actor: actor)
  }

  static func setup(_ env: SiltaEnvironment) throws {
    try WorkspaceConfigTests.apply(
      WorkspaceConfigTests.minimal + "topics: [{slug: release}]", to: env.db)
    try WorkspaceSelection.use("acme", in: env.db)
  }

  static func human() throws -> ActorID {
    try ActorID.detect(
      environment: ["USER": "acme"], terminal: .init(stdin: true, stdout: true),
      session: "acme")
  }

  @Test func creationMatrixParentIsolationAndAtomicSequences() async throws {
    try await withScratchDirectory { home in
      let env = try Self.environment(home)
      try Self.setup(env)
      let service = TaskService(environment: env)
      let proposal = try await service.add(TaskDraft(title: "Idea"), directory: home)
      #expect(proposal.status == "proposed")
      var root = TaskDraft(title: "Requested")
      root.start = true
      let started = try await service.add(root, directory: home)
      #expect(started.ref == "AC-2" && started.status == "doing")
      var child = TaskDraft(title: "Child")
      child.parent = "task:AC-2"
      child.topics = ["release"]
      #expect(try await service.add(child, directory: home).status == "todo")
      let other = TaskService(
        environment: try Self.environment(
          home, actor: .agent(tool: "codex", session: "other")))
      #expect(try await other.add(child, directory: home).status == "proposed")
      child.topics = ["missing"]
      await #expect(throws: TaskError.self) { _ = try await service.add(child, directory: home) }
      #expect(try service.list().map(\.ref) == ["AC-1", "AC-2", "AC-3"])
      #expect(try other.list().map(\.ref) == ["AC-2", "AC-3", "AC-4"])
      let human = TaskService(environment: try Self.environment(home, actor: Self.human()))
      #expect(try await human.add(TaskDraft(title: "Human task"), directory: home).ref == "AC-5")
      #expect(try human.show("AC-5").status == "todo")
      for ref in ["AC-0", "AC-01", "task:AC-2/1", "ZZ-2"] {
        #expect(throws: TaskError.self) { _ = try service.show(ref) }
      }
      #expect(try service.show("AC-3").links.first?.target == "topic:release")
    }
  }

  @Test func claimsUseExactSessionAndTwoHourBoundary() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: Self.now)
      let env = try Self.environment(home, clock: clock)
      try Self.setup(env)
      var draft = TaskDraft(title: "Claim")
      draft.start = true
      let service = TaskService(environment: env)
      _ = try await service.add(draft, directory: home)
      let rival = TaskService(
        environment: try Self.environment(
          home, actor: .agent(tool: "codex", session: "other"), clock: clock))
      await #expect(throws: TaskError.claimed("AC-1", holder: Self.agent.description, minutes: 0)) {
        _ = try await rival.start("AC-1", directory: home)
      }
      clock.advance(milliseconds: 7_199_000)
      _ = try service.submit("AC-1")
      #expect(try service.show("AC-1").claimedAt == Self.timestamp(clock.now()))
      clock.advance(milliseconds: 7_199_000)
      await #expect(throws: TaskError.self) { _ = try await rival.start("AC-1", directory: home) }
      clock.advance(milliseconds: 1000)
      #expect(try await rival.start("AC-1", directory: home).status == "doing")
      #expect(try service.show("AC-1").claimedBy == "agent:codex:other")
      await #expect(throws: ActorError.self) {
        _ = try await service.start("AC-1", steal: true, directory: home)
      }
      let human = TaskService(
        environment: try Self.environment(home, actor: Self.human(), clock: clock))
      _ = try await human.start("AC-1", steal: true, directory: home)
      #expect(try service.show("AC-1").claimedBy == "human:acme")
    }
  }

  static func timestamp(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }

  @Test func transitionsResultsAndUnknownColumnsArePreserved() async throws {
    try await withScratchDirectory { home in
      let env = try Self.environment(home)
      try Self.setup(env)
      let service = TaskService(environment: env)
      _ = try await service.add(TaskDraft(title: "Proposal"), directory: home)
      await #expect(throws: TaskError.self) { _ = try await service.start("AC-1", directory: home) }
      await #expect(throws: TaskError.self) {
        _ = try await service.close("AC-1", result: "Bypass", directory: home)
      }
      await #expect(throws: TaskError.self) {
        _ = try await service.close("AC-1", result: " ", dropped: true, directory: home)
      }
      var draft = TaskDraft(title: "Work")
      draft.start = true
      _ = try await service.add(draft, directory: home)
      try env.db.write {
        try $0.database.execute(sql: "ALTER TABLE task ADD COLUMN future TEXT DEFAULT 'kept'")
        try $0.database.execute(sql: "UPDATE task SET future='retained'")
      }
      _ = try await service.start("AC-2", directory: home)
      _ = try service.submit("AC-2")
      _ = try await service.close("AC-2", result: "Finished.", directory: home)
      #expect(try service.show("AC-2").result == "Finished.")
      #expect(try service.show("AC-2").claimedBy == nil)
      await #expect(throws: TaskError.self) { _ = try await service.start("AC-2", directory: home) }
      #expect(
        try env.db.read { try String.fetchAll($0, sql: "SELECT future FROM task") } == [
          "retained", "retained",
        ])
      try env.db.write {
        try $0.database.execute(sql: "UPDATE meta SET value='2' WHERE key='min_writer_version'")
      }
      await #expect(throws: StorageError.schemaTooNew) {
        _ = try await service.close("AC-1", result: "Dropped.", dropped: true, directory: home)
      }
      #expect(try service.show("AC-1").status == "proposed")
    }
  }

  @Test func secretsRedactAndHumanOverrideNeedsHuman() async throws {
    try await withScratchDirectory { home in
      let env = try Self.environment(home)
      try Self.setup(env)
      let service = TaskService(environment: env)
      let secret = "Pwd=" + "acme-value"
      var draft = TaskDraft(title: secret)
      draft.description = secret
      draft.start = true
      let result = try await service.add(draft, directory: home)
      #expect(result.warnings == [SecretGuard.warning])
      #expect(try service.show("AC-1").title == "[REDACTED:password]")
      #expect(try service.show("AC-1").description == "[REDACTED:password]")
      let finished = try await service.close("AC-1", result: secret, directory: home)
      #expect(finished.warnings == [SecretGuard.warning])
      #expect(
        try service.show("AC-1", timeline: true).timeline?.filter { $0.kind == "secret_redacted" }
          .count == 2)
      let human = TaskService(environment: try Self.environment(home, actor: Self.human()))
      await #expect(throws: SecretError.self) { _ = try await human.add(draft, directory: home) }
      draft.allowSecret = true
      await #expect(throws: ActorError.self) { _ = try await service.add(draft, directory: home) }
      #expect(try await human.add(draft, directory: home).warnings.isEmpty)
    }
  }

  @Test func humanGateAndAnyWarningHaveCurrentCallers() async throws {
    try await withScratchDirectory { home in
      let env = try Self.environment(home)
      try Self.setup(env)
      let service = TaskService(environment: env)
      var draft = TaskDraft(title: "Gated")
      draft.start = true
      _ = try await service.add(draft, directory: home)
      try env.db.write {
        try $0.database.execute(sql: "UPDATE workspace SET settings='{\"review_gate\":\"human\"}'")
      }
      await #expect(throws: TaskError.gate("AC-1")) {
        _ = try await service.close("AC-1", result: "Finished.", directory: home)
      }
      var options = TaskCommit()
      options.force = true
      await #expect(throws: ActorError.self) {
        _ = try await service.close("AC-1", result: "Finished.", commit: options, directory: home)
      }
      let human = TaskService(environment: try Self.environment(home, actor: Self.human()))
      _ = try await human.start("AC-1", steal: true, directory: home)
      _ = try await human.close("AC-1", result: nil, commit: options, directory: home)
      #expect(try service.show("AC-1").status == "done")
    }
  }
}
