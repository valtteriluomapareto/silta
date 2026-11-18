import Foundation
import SiltaAppSupport

@MainActor enum DocsContent {
  struct Section: Identifiable {
    let id: String
    let groups: [DocsModel.Group]
    var title: String {
      if id == "unknown" { return "Attachments not recorded" }
      if id == "none" { return "No attachments" }
      if id.hasPrefix("app:") { return String(id.dropFirst(4)) }
      if id.hasPrefix("topic:") { return "Topic " + id.dropFirst(6) }
      if id.hasPrefix("edge:") {
        let parts = id.dropFirst(5).split(separator: "/", maxSplits: 2)
        if parts.count == 3 { return "\(parts[0]) → \(parts[1]) · \(parts[2])" }
      }
      return id
    }
  }

  static func groups(_ entries: [AppDocument]) -> [DocsModel.Group] {
    Dictionary(grouping: entries, by: \.slug).map { DocsModel.Group(id: $0.key, entries: $0.value) }
      .sorted { $0.id < $1.id }
  }

  static func sections(_ groups: [DocsModel.Group]) -> [Section] {
    var result: [String: [DocsModel.Group]] = [:]
    for group in groups {
      let refs = group.preferred?.about
      let keys = refs.map { $0.isEmpty ? ["none"] : $0 } ?? ["unknown"]
      for key in Set(keys) { result[key, default: []].append(group) }
    }
    let kinds = ["edge:", "app:", "topic:", "none", "unknown"]
    func rank(_ id: String) -> Int { kinds.firstIndex { id.hasPrefix($0) } ?? kinds.count }
    return result.map { Section(id: $0.key, groups: $0.value) }.sorted {
      rank($0.id) == rank($1.id) ? $0.id < $1.id : rank($0.id) < rank($1.id)
    }
  }

  static func row(_ group: DocsModel.Group) -> String {
    guard let document = group.preferred else { return "" }
    let pending = group.entries.filter { $0.state == "proposed" }
      .map { "@\($0.revision) proposed" }
    let revision = document.state == "proposed" ? [] : ["@\(document.revision)"]
    return
      ([document.kind ?? "Kind not recorded"] + revision + pending
      + (document.archived ? ["archived"] : [])).joined(separator: " · ")
  }

  static func readerText(_ document: AppDocument?, body: String, diagnostic: String) -> String {
    document == nil ? diagnostic : body
  }

  static func proposal(in revisions: [AppDocument]) -> AppDocument? {
    revisions.filter { $0.state == "proposed" }.max { $0.revision < $1.revision }
  }

  static func attribution(_ doc: AppDocument, now: Date) -> String {
    let actor = doc.actor.map { ActorPresentation($0).name } ?? "Unknown author"
    let age = RelativeAge.text(doc.createdAt, now: now)
    let source = doc.sourceTask.map { "from " + $0 }
    let creation =
      ([actor + " proposed revision @\(doc.revision)"] + [source, age].compactMap { $0 })
      .joined(separator: " · ")
    let message = doc.message.map { " · “" + $0 + "”" } ?? ""
    if doc.state == "proposed" { return creation + message }
    let accepted =
      doc.triagedBy.map { doc.state.capitalized + " by " + ActorPresentation($0).name }
      ?? "\(doc.state.capitalized) revision @\(doc.revision)"
    let acceptedAge = RelativeAge.text(doc.triagedAt, now: now).map { " " + $0 } ?? ""
    return accepted + acceptedAge + " · Created by " + actor
      + (source.map { " " + $0 } ?? "") + message
  }
}
