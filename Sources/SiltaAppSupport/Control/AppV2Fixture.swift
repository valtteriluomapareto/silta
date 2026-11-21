#if DEBUG
  public import Foundation
  import SiltaCore

  /// Shared synthetic task and workspace data for viewer launch, previews and tests.
  public enum AppV2Fixture {
    /// Human identity shared by fixture launch and tests.
    public static let user = "acme"

    /// Frozen Monday used for relative times and completion-week checks.
    public static let now = Date(timeIntervalSince1970: 1_794_830_400)

    /// Creates the fixture in an absent isolated data home; never opens existing data.
    public static func seed(home: URL) throws {
      guard !FileManager.default.fileExists(atPath: home.path) else {
        throw WorkspaceError.invalid(["Fixture home must be absent."])
      }
      let location = try SiltaHome.resolve(environment: ["SILTA_HOME": home.path])
      guard location.permitsDeterminism else {
        throw WorkspaceError.invalid(["Fixture home must be a temporary isolated directory."])
      }
      let clock = IncrementingClock(start: now.addingTimeInterval(-360))
      let ids = SeededIDGenerator(seed: 73)
      let store = DatabaseStore(home: location.url, clock: clock, jitter: { 0 })
      let config = try WorkspaceConfig.parse(configuration)
      try store.write { tx in
        try config.apply(in: tx, ids: ids, at: now)
        for task in tasks { try task.insert(in: tx, ids: ids, at: now.addingTimeInterval(-3600)) }
      }
      let actor = ActorID.agent(tool: "claude", session: "fixture")
      let environment = SiltaEnvironment(
        clock: clock, ids: ids, git: SystemGitRunner(environment: [:]), home: location, db: store,
        log: FixtureLog(), actor: actor, human: .human(name: user))
      var question = CommentDraft(
        body: "The backend sends categories the app doesn't know yet. Should unknown values be "
          + "dropped, or shown under Other?", kind: "question")
      question.recipients = ["human:\(user)"]
      let service = TaskService(environment: environment, workspace: "acme")
      _ = try service.comment("AC-12", question)
      _ = try service.link(
        "AC-9", target: "url:https://github.com/acme/example/pull/41", relation: "about")
      try answeredHumanQuestion(environment)
      try reviewThreads(environment)
      var block = TaskBlock(why: "Needs the rounded totals first.")
      block.on = ["AC-19"]
      _ = try service.block("AC-17", block)
      try store.write {
        try DebugTaskFixture.complete(19, in: $0, at: now.addingTimeInterval(-1800))
        try inspectorFacts(in: $0)
        // Codex went quiet on AC-14 three hours ago, so its claim has expired.
        try DebugTaskFixture.claim(14, heartbeat: now.addingTimeInterval(-3 * 3600), in: $0)
      }
      _ = try service.link(
        "AC-8", target: "url:https://github.com/acme/example/pull/38", relation: "about")
    }

    /// The facts the inspector shows beyond the plan: acceptance on AC-14, and on AC-8 a
    /// result with its Friction line, the completion branch and a dirty worktree.
    private static func inspectorFacts(in tx: StorageTransaction) throws {
      try DebugTaskFixture.annotate(
        14,
        acceptance: "- A failed registration retries with capped backoff.\n"
          + "- Tokens older than an hour are dropped, not retried.\n",
        worktree: "/Users/acme/worktrees/mobile-push", in: tx)
      try DebugTaskFixture.annotate(
        8,
        result: "Order totals are stored and returned as integer cents. The API keeps a decimal "
          + "field for one release. Verified with OrderTotalsTests.\nMerged in #38 (1111111).\n"
          + "Friction: The fixture had no multi-currency orders, so rounding was checked by hand.",
        doneBranch: "main", doneDirty: true, in: tx)
    }

    /// A review on AC-9: an open finding Codex replied to, and a finding Claude resolved
    /// after Codex's reply, so the inspector shows an open and a resolved thread.
    private static func reviewThreads(_ environment: SiltaEnvironment) throws {
      func service(_ actor: ActorID) -> TaskService {
        TaskService(
          environment: SiltaEnvironment(
            clock: environment.clock, ids: environment.ids, git: environment.git,
            home: environment.home, db: environment.db, log: environment.log, actor: actor,
            human: environment.human),
          workspace: "acme")
      }
      let reviewer = service(.agent(tool: "claude", session: "review"))
      let author = service(.agent(tool: "codex", session: "fixture"))
      let open = try reviewer.comment(
        "AC-9",
        CommentDraft(
          body: "Review (round 1, major): retries back off but never stop. "
            + "PushRetry.schedule doubles the delay without a cap, so a device that stays "
            + "offline keeps a retry alive for days and the queue grows without bound. The "
            + "plan says retries give up after an hour.\n\nFix: cap the delay at five "
            + "minutes and drop the registration after an hour."))
      var reply = CommentDraft(
        body: "Capped at five minutes and dropped after an hour. "
          + "PushRetryTests.retriesGiveUpAfterAnHour proves it with the fake clock.")
      reply.replyTo = open.comment.ref
      _ = try author.comment("AC-9", reply)
      let closed = try reviewer.comment(
        "AC-9",
        CommentDraft(body: "Review (round 1, minor): Retry-After is ignored; honour it first."))
      var fixed = CommentDraft(body: "Honoured; RetryAfterTests.headerWinsOverBackoff.")
      fixed.replyTo = closed.comment.ref
      _ = try author.comment("AC-9", fixed)
      _ = try reviewer.updateComments([closed.comment.ref], action: .resolve)
    }

    /// The human asks Codex on AC-14 and Codex answers, which leaves an answer to accept.
    private static func answeredHumanQuestion(_ environment: SiltaEnvironment) throws {
      func service(_ actor: ActorID) -> TaskService {
        TaskService(
          environment: SiltaEnvironment(
            clock: environment.clock, ids: environment.ids, git: environment.git,
            home: environment.home, db: environment.db, log: environment.log, actor: actor,
            human: environment.human),
          workspace: "acme")
      }
      var question = CommentDraft(
        body: "Should retries give up after an hour?", kind: "question")
      question.recipients = ["agent:codex:fixture"]
      let asked = try service(environment.human).comment("AC-14", question)
      var answer = CommentDraft(
        body: "Yes. After an hour the token is usually stale, so the app drops the "
          + "registration and asks for a fresh token on next launch.", kind: "answer")
      answer.replyTo = asked.comment.ref
      _ = try service(.agent(tool: "codex", session: "review")).comment("AC-14", answer)
    }

    private static var tasks: [DebugTaskFixture] {
      let rows = [
        DebugTaskFixture(6, "Order list skeleton", app: "acme-mobile", status: "done"),
        DebugTaskFixture(7, "Push token refresh", app: "acme-mobile", status: "done"),
        DebugTaskFixture(8, "Order totals in cents", app: "acme-backend", status: "done"),
        DebugTaskFixture(9, "Backend push retries", app: "acme-backend", status: "review"),
        DebugTaskFixture(12, "Parse push categories", app: "acme-mobile", status: "doing"),
        DebugTaskFixture(14, "Retry push registrations", app: "acme-mobile", status: "doing"),
        DebugTaskFixture(15, "Order history page", app: "acme-web", status: "todo"),
        DebugTaskFixture(16, "Paginate the orders endpoint", app: "acme-backend", status: "todo"),
        DebugTaskFixture(17, "Offline banner", app: "acme-mobile", status: "todo"),
        DebugTaskFixture(18, "Error code cleanup", app: "acme-backend", status: "todo"),
        DebugTaskFixture(19, "Round order totals", app: "acme-backend", status: "todo"),
        DebugTaskFixture(21, "Rate-limit push sends", app: "acme-backend", status: "proposed"),
        DebugTaskFixture(22, "Cache the order list", app: "acme-mobile", status: "proposed"),
        DebugTaskFixture(23, "Drop the legacy v1 client", app: "acme-web", status: "proposed"),
      ]
      return rows.map { row in
        var task = row
        let sequence = task.sequence
        let status = task.status
        if sequence == 22 { task.creator = "agent:claude:fixture" }
        if status == "doing" {
          task.claimant = sequence == 12 ? "agent:claude:fixture" : "agent:codex:fixture"
        }
        if status == "doing" || status == "review" {
          task.plan =
            "- [x] Read the contract\n- [x] Model the values\n"
            + (sequence == 14 || status == "review"
              ? "- [x] Parse and test\n" : "- [ ] Parse and test\n")
            + (status == "review" ? "- [x] Commit and submit\n" : "- [ ] Commit and submit\n")
        }
        return task
      }
    }

    private static let configuration = """
      workspace: {slug: acme, name: Acme, task_prefix: AC}
      repos: [{slug: mobile}, {slug: backend}, {slug: web}]
      apps:
        - {slug: acme-mobile, repo: mobile, ref: origin/main, summary: Flutter app for customers}
        - {slug: acme-backend, repo: backend, ref: origin/main, summary: API for mobile and web}
        - {slug: acme-web, repo: web, ref: origin/main, summary: Customer web shop}
      services: [push, payments]
      edges:
        - {from: acme-mobile, to: acme-backend, kind: http-api, summary: Orders and registration}
        - {from: acme-mobile, to: 'service:push', kind: sdk, summary: Push notifications}
        - {from: acme-backend, to: 'service:payments', kind: http-api, summary: Card payments}
        - {from: acme-web, to: acme-backend, kind: graphql, summary: Account and order history}
      """
  }

  private struct FixtureLog: Log {
    func record(_ entry: LogEntry) {}
  }
#endif
