import Foundation
import SiltaAppSupport

nonisolated enum SidebarContent {
  /// An app's colour: the one chosen on this Mac, else its automatic colour; nil when the
  /// map lacks the app.
  static func appColor(slug: String, apps: [AppMapApp], chosen: [String: String]) -> String? {
    guard apps.contains(where: { $0.slug == slug }) else { return nil }
    return chosen[slug] ?? AppPalette.automatic(slug)
  }

  static func claimTitle(_ task: AppTask, now: Date) -> String {
    if task.claimExpired(at: now) { return task.ref + " · expired" }
    return task.ref
      + (task.steps.isEmpty
        ? "" : " · step \(task.steps.filter(\.done).count) of \(task.steps.count)")
  }

  static func claimSubtitle(_ task: AppTask, now: Date) -> String {
    TaskPresentation.claimLine(task, now: now) ?? task.ref
  }

  /// The Claimed now heading, counting claims another agent may now take over.
  static func claimHeading(_ doing: [AppTask], now: Date) -> String {
    let expired = doing.filter { $0.claimExpired(at: now) }.count
    return "Claimed now" + (expired > 0 ? " · \(expired) expired" : "")
  }

  /// The Claimed now card shows at most this many claims so the navigation keeps its room.
  static let claimLimit = 3

  /// A short claim heartbeat age for the Claimed now card, such as "6 min".
  static func claimAge(_ task: AppTask, now: Date) -> String? {
    RelativeAge.text(task.claimedAt, now: now, short: true)
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
    guard documents > 0 || !more.isEmpty else {
      return stale ? "No documents (stale)" : "No documents"
    }
    let archived = Set(page.entries.filter(\.archived).map(\.slug)).count
    let proposals = Set(page.entries.filter { $0.state == "proposed" && !$0.archived }.map(\.ref))
      .count
    let noun = documents == 1 && more.isEmpty ? "doc" : "docs"
    var parts = [
      "\(documents)\(more) \(noun)" + (archived > 0 ? ", \(archived)\(more) archived" : "")
    ]
    if proposals > 0 {
      parts.append(
        "\(proposals)\(more) \(proposals == 1 && more.isEmpty ? "proposal" : "proposals") waiting on you"
      )
    }
    return parts.joined(separator: " · ") + (stale ? " (stale)" : "")
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
