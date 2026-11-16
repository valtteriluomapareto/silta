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
      _ = try TaskService(environment: environment, workspace: "acme").comment("AC-12", question)
    }

    private static var tasks: [DebugTaskFixture] {
      let rows: [(Int64, String, String, String)] = [
        (6, "Order list skeleton", "acme-mobile", "done"),
        (7, "Push token refresh", "acme-mobile", "done"),
        (8, "Order totals in cents", "acme-backend", "done"),
        (9, "Backend push retries", "acme-backend", "review"),
        (12, "Parse push categories", "acme-mobile", "doing"),
        (14, "Retry push registrations", "acme-mobile", "doing"),
        (15, "Order history page", "acme-web", "todo"),
        (16, "Paginate the orders endpoint", "acme-backend", "todo"),
        (17, "Offline banner", "acme-mobile", "todo"),
        (18, "Error code cleanup", "acme-backend", "todo"),
        (21, "Rate-limit push sends", "acme-backend", "proposed"),
        (22, "Cache the order list", "acme-mobile", "proposed"),
        (23, "Drop the legacy v1 client", "acme-web", "proposed"),
      ]
      return rows.map { sequence, title, app, status in
        var task = DebugTaskFixture(sequence, title, app: app, status: status)
        if sequence == 22 { task.creator = "agent:claude:fixture" }
        if status == "doing" {
          task.claimant = sequence == 12 ? "agent:claude:fixture" : "agent:codex:fixture"
          task.plan =
            "- [x] Read the contract\n- [x] Model the values\n"
            + (sequence == 14 ? "- [x] Parse and test\n" : "- [ ] Parse and test\n")
            + "- [ ] Commit and submit\n"
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
