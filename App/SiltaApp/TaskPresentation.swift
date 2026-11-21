import Foundation
import SiltaAppSupport

nonisolated enum TaskPresentation {
  static func claimant(_ actor: String?) -> String {
    guard let actor else { return "—" }
    let presentation = ActorPresentation(actor)
    let parts = actor.split(separator: ":", maxSplits: 2)
    if parts.count == 3, presentation.name != actor {
      return presentation.name + " · session " + parts[2]
    }
    return presentation.name
  }

  static func progress(_ steps: [AppPlanStep], revision: Int) -> String {
    let value = "revision \(revision)"
    guard !steps.isEmpty else { return value }
    return "step \(steps.filter(\.done).count) of \(steps.count) · " + value
  }

  static func cardMetadata(
    _ task: AppTask, asked: Bool, questionAuthor: String? = nil, now: Date
  ) -> String? {
    if asked {
      return questionAuthor.map { ActorPresentation($0).name + " · asked you" } ?? "Asked you"
    }
    if task.status == "review" {
      return task.submission.map { ActorPresentation($0.actor).name + " · waiting for your review" }
        ?? "Waiting for your review"
    }
    if task.status == "proposed" { return "Proposed by " + ActorPresentation(task.createdBy).name }
    guard task.status == "doing" else { return nil }
    return claimLine(task, now: now)
  }

  /// A Doing task's claim: live, expired (another agent may start it), or released.
  enum Claim: Equatable {
    /// The age is nil when the heartbeat is unreadable.
    case live(age: String)
    case expired(idle: String?)
    case handedOff
  }

  /// The claim state by Core's rules, aged from the claim heartbeat rather than the last
  /// task update. A Doing task without a claimant is handed off only when Core can resume
  /// it; a promoted one is not.
  static func claim(_ task: AppTask, now: Date) -> Claim? {
    guard task.status == "doing" else { return nil }
    guard task.claimedBy != nil else { return task.resumeAvailable ? .handedOff : nil }
    let age = RelativeAge.text(task.claimedAt, now: now)
    if task.claimExpired(at: now) {
      return .expired(
        idle: task.claimExpiresAt == nil
          ? nil : RelativeAge.text(task.claimedAt, now: now, short: true))
    }
    return .live(age: age ?? "just now")
  }

  /// Who holds a Doing task and how fresh the claim is, such as `Codex · active 6 min ago`.
  static func claimLine(_ task: AppTask, now: Date) -> String? {
    let actor = task.claimedBy.map { ActorPresentation($0).name }
    switch claim(task, now: now) {
    case .live(let age): return [actor, "active " + age].compactMap { $0 }.joined(separator: " · ")
    case .expired(let idle):
      return [actor, "claim expired", idle.map { "idle " + $0 }].compactMap { $0 }
        .joined(separator: " · ")
    case .handedOff: return "Handed off · ready to resume"
    case nil: return nil
    }
  }

  struct ClaimBanner: Equatable {
    let title: String
    let body: String
  }

  /// The inspector's warning for an expired claim: when it lapsed, the last sign of work,
  /// and what Core now allows.
  static func claimBanner(_ task: AppTask, now: Date) -> ClaimBanner? {
    guard task.status == "doing", let holder = task.claimedBy, task.claimExpired(at: now)
    else { return nil }
    let name = ActorPresentation(holder).name
    let next = "Another agent can now start it without stealing the claim."
    guard let expiry = task.claimExpiresAt else {
      return ClaimBanner(
        title: "Claim unreadable",
        body: name + "'s claim has no readable heartbeat, so Core refuses to start the task. "
          + "Run `silta doctor` to repair it.")
    }
    let lapsed = expiry.ISO8601Format(.init(includingFractionalSeconds: true))
    let wrote = RelativeAge.text(task.claimedAt, now: now) ?? "just now"
    let step =
      task.steps.isEmpty ? "" : " (step \(task.steps.filter(\.done).count) of \(task.steps.count))"
    return ClaimBanner(
      title: "Claim expired " + (RelativeAge.text(lapsed, now: now) ?? "just now"),
      body: name + " last wrote " + wrote + step + ". " + next)
  }

  /// A short status for a task row in the map inspector: who holds it and which step, or
  /// its status.
  static func mapStatus(_ task: AppTask) -> String {
    if let actor = task.claimedBy, !task.steps.isEmpty {
      return ActorPresentation(actor).name + " · step \(task.steps.filter(\.done).count) of "
        + "\(task.steps.count)"
    }
    return task.status.capitalized
  }
}
