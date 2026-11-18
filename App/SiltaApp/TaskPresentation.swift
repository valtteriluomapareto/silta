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
    let actor = task.claimedBy.map { ActorPresentation($0).name }
    let age = RelativeAge.text(task.updatedAt, now: now).map { "updated " + $0 }
    return [actor, age].compactMap { $0 }.joined(separator: " · ")
  }
}
