import Foundation
import SiltaAppSupport

/// What the inspector says about a task beyond its plan: blockers, result, links and
/// relations, as `task show` reports them.
nonisolated enum TaskFacts {
  enum BlockerState: Equatable { case done, open, dropped }

  struct Blocker: Equatable {
    /// The blocker as written: a bare task ref, an `ext:` party or a URL.
    let ref: String
    /// A task blocker's title and status, when the detail read found it.
    let detail: String?
    let state: BlockerState
  }

  struct Waiting: Equatable {
    let blockers: [Blocker]
    let heading: String
    let why: String
    let footer: String
    let followUp: String?
  }

  struct PullRequest: Equatable {
    let title: String
    let url: String
  }

  struct Related: Equatable {
    let ref: String
    let title: String
  }

  static func waiting(_ task: AppTask) -> Waiting? {
    guard let waiting = task.waiting else { return nil }
    let blockers = waiting.on.map { blocker -> Blocker in
      guard let ref = AppWaiting.taskRef(blocker) else {
        return Blocker(ref: blocker, detail: nil, state: .open)
      }
      let related = task.related(ref)
      let state: BlockerState =
        waiting.dropped.contains(blocker)
        ? .dropped : related?.status == "done" || waiting.ready ? .done : .open
      return Blocker(
        ref: ref, detail: related.map { $0.title + " · " + $0.status }, state: state)
    }
    let done = blockers.filter { $0.state == .done }.count
    let age = waiting.ageDays == 0 ? "Blocked today." : "Blocked \(days(waiting.ageDays))."
    let next =
      !waiting.dropped.isEmpty
      ? "A blocker was dropped: re-plan the task."
      : waiting.ready ? "Ready to unblock." : "Unblock is offered when every blocker is done."
    return Waiting(
      blockers: blockers, heading: "Waiting on · \(done) of \(blockers.count) done",
      why: waiting.why, footer: age + " " + next,
      followUp: task.followUpAt.flatMap { day($0) }.map { "Follow up " + $0 })
  }

  /// The result Markdown and its `Friction:` line, shown apart.
  static func result(_ task: AppTask) -> (body: String, friction: String?)? {
    guard let result = task.result, !result.isEmpty else { return nil }
    return splitResult(result)
  }

  static func splitResult(_ text: String) -> (body: String, friction: String?) {
    var friction: String?
    var kept: [Substring] = []
    for paragraph in text.split(separator: "\n\n", omittingEmptySubsequences: false) {
      let line = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
      if friction == nil, line.hasPrefix("Friction:"), !line.contains("\n") {
        friction = line.dropFirst("Friction:".count).trimmingCharacters(in: .whitespaces)
      } else {
        kept.append(paragraph)
      }
    }
    return (
      kept.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines), friction
    )
  }

  /// The short completion commit and branch, such as `9f2c41e · main`.
  static func commit(_ task: AppTask) -> String? {
    guard let sha = task.doneSHA else { return nil }
    return ([String(sha.prefix(7))] + [task.doneBranch].compactMap { $0 }).joined(separator: " · ")
  }

  static func pullRequests(_ task: AppTask) -> [PullRequest] {
    task.links.compactMap { pullRequest($0.target) }
  }

  /// Links other than pull requests and blockers, which have their own rows.
  static func otherLinks(_ task: AppTask) -> [AppTaskLink] {
    task.links.filter { $0.rel != "blocked_by" && pullRequest($0.target) == nil }
  }

  /// A GitHub pull request or GitLab merge request link, titled by its number.
  static func pullRequest(_ target: String) -> PullRequest? {
    guard target.hasPrefix("url:") else { return nil }
    let url = String(target.dropFirst("url:".count))
    let parts = url.split(separator: "/")
    guard parts.count >= 2, let number = Int(parts[parts.count - 1]) else { return nil }
    switch parts[parts.count - 2] {
    case "pull": return PullRequest(title: "PR #\(number)", url: url)
    case "merge_requests": return PullRequest(title: "MR !\(number)", url: url)
    default: return nil
    }
  }

  static func parent(_ task: AppTask) -> Related? {
    task.parent.map { Related(ref: $0, title: task.related($0)?.title ?? "") }
  }

  static func subtasks(_ task: AppTask) -> [Related] {
    task.subtasks.map { Related(ref: $0.ref, title: $0.title + " · " + $0.status) }
  }

  /// Who created the task and on which day, such as `Codex · 12 Nov`.
  static func created(_ task: AppTask) -> String {
    let name = ActorPresentation(task.createdBy).name
    return day(String(task.createdAt.prefix(10)), weekday: false).map { name + " · " + $0 } ?? name
  }

  /// A released claim: the next agent can resume from the handoff.
  static func handoff(_ task: AppTask) -> String? {
    guard task.resumeAvailable, task.claimedBy == nil else { return nil }
    return task.handedOff.map { "Handed off in \($0) · ready to resume" }
      ?? "Claim released · ready to resume"
  }

  private static func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }

  /// A stored UTC day (`2026-11-24`) as `Mon 24 Nov`, or `24 Nov` without the weekday.
  private static func day(_ value: String, weekday: Bool = true) -> String? {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = .gmt
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: value) else { return nil }
    parser.dateFormat = weekday ? "EEE d MMM" : "d MMM"
    return parser.string(from: date)
  }
}
