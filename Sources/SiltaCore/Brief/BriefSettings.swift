/// Non-default workspace settings. Empty defaults encode as an empty object (D39).
package struct BriefSettings: Encodable, Sendable {
  let proposals: String?
  let reviewGate: String?
  let archiveAfterDays: Int?
  let staleDays: Int?

  enum CodingKeys: String, CodingKey {
    case proposals
    case reviewGate = "review_gate"
    case archiveAfterDays = "archive_after_days"
    case staleDays = "stale_days"
  }

  init(_ settings: WorkspaceSettings, workspace: String) throws {
    let defaults = WorkspaceSettings(workspace: workspace, json: "{}")
    proposals = try settings.proposals == defaults.proposals ? nil : settings.proposals.rawValue
    reviewGate = try settings.reviewGate == defaults.reviewGate ? nil : settings.reviewGate.rawValue
    archiveAfterDays =
      try settings.archiveAfterDays == defaults.archiveAfterDays
      ? nil : settings.archiveAfterDays
    staleDays = try settings.staleDays == defaults.staleDays ? nil : settings.staleDays
  }

  var text: String {
    var items: [String] = []
    if let proposals {
      items.append("proposals: \(proposals) (ask in chat before adding a task)")
    }
    if let reviewGate {
      let gloss =
        reviewGate == "human"
        ? "human approval required before done" : "warn if latest review requests changes"
      items.append("review_gate: \(reviewGate) (\(gloss))")
    }
    if let archiveAfterDays {
      items.append("archive_after_days: \(archiveAfterDays) (days before closed tasks archive)")
    }
    if let staleDays { items.append("stale_days: \(staleDays) (days before docs are stale)") }
    return items.isEmpty ? "" : "settings: " + items.joined(separator: "; ") + "\n"
  }
}
