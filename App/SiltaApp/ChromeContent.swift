import Foundation
import SiltaAppSupport

nonisolated struct BoardMenuContent {
  let title: String
  let proposedCount: Int

  init(app: String?, apps: [AppMapApp], proposals: [AppTask], showing: Bool) {
    let name = app.map { slug in apps.first { $0.slug == slug }?.name ?? slug } ?? "All apps"
    title = name + (showing ? " · proposed" : "")
    proposedCount = proposals.filter { app == nil || $0.app == app }.count
  }
}

nonisolated enum SidebarContent {
  static func appColor(index: Int) -> String {
    ["SecondaryInk", "AppViolet", "AppClay"][index % 3]
  }

  static func claimTitle(_ task: AppTask) -> String {
    task.ref
      + (task.steps.isEmpty
        ? "" : " · step \(task.steps.filter(\.done).count) of \(task.steps.count)")
  }

  static func claimSubtitle(_ task: AppTask, now: Date) -> String {
    let actor = task.claimedBy.map { ActorPresentation($0).name } ?? "Unknown actor"
    return actor + (RelativeAge.text(task.updatedAt, now: now).map { " · updated " + $0 } ?? "")
  }

  /// A short age for the Claimed now card, such as "6 min".
  static func claimAge(_ task: AppTask, now: Date) -> String? {
    RelativeAge.text(task.updatedAt, now: now).map {
      $0.hasSuffix(" ago") ? String($0.dropLast(4)) : $0
    }
  }

  static func documentCount(_ page: AppDocumentList?, stale: Bool = false) -> String {
    guard let page else { return stale ? "Unavailable" : "…" }
    return "\(Set(page.entries.map(\.slug)).count)" + (page.nextOffset == nil ? "" : "+")
      + (stale ? " (stale)" : "")
  }

  static func refreshText(loading: Bool, failure: Bool, checkedAt: Date?, now: Date) -> String {
    if loading { return "Updating…" }
    if failure { return "Couldn't read the Silta data" }
    return RelativeAge.text(
      checkedAt?.ISO8601Format(.init(includingFractionalSeconds: true)), now: now
    ).map { "Updated " + $0 } ?? "Not loaded"
  }
}

@MainActor enum DocsChromeContent {
  struct Banner {
    let text: String
    let proposal: AppDocument
    let accepted: AppDocument?
  }

  static func catalogSummary(_ page: AppDocumentList?, stale: Bool) -> String {
    guard let page else { return stale ? "Documents unavailable" : "Workspace documents" }
    let more = page.nextOffset == nil ? "" : "+"
    let documents = Set(page.entries.map(\.slug)).count
    let archived = Set(page.entries.filter(\.archived).map(\.slug)).count
    let proposed = Set(page.entries.filter { $0.state == "proposed" && !$0.archived }.map(\.slug))
      .count
    var parts = ["\(documents)\(more) docs" + (archived > 0 ? ", \(archived) archived" : "")]
    if proposed > 0 {
      parts.append("\(proposed)\(more) proposal\(proposed == 1 ? "" : "s") waiting on you")
    }
    return parts.joined(separator: " · ")
  }

  static func aboutLabel(_ ref: String) -> String {
    if ref.hasPrefix("edge:") {
      let parts = ref.dropFirst(5).split(separator: "/", maxSplits: 2)
      if parts.count == 3 { return "About \(parts[0]) → \(parts[1])" }
    }
    return "About " + ref
  }

  static func banner(document: AppDocument?, revisions: [AppDocument], partial: Bool, now: Date)
    -> Banner?
  {
    guard let document else { return nil }
    if document.state == "proposed" {
      let accepted = revisions.filter { $0.state == "accepted" }.max { $0.revision < $1.revision }
      let suffix =
        accepted.map { "accepted is @\($0.revision)" }
        ?? (partial ? "accepted revision not loaded" : "no accepted revision")
      return Banner(text: "Not accepted yet · " + suffix, proposal: document, accepted: accepted)
    }
    guard let proposal = DocsContent.proposal(in: revisions) else { return nil }
    return Banner(
      text: DocsContent.attribution(proposal, now: now), proposal: proposal, accepted: nil)
  }
}
