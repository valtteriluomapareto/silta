import Foundation
import SiltaAppSupport

@MainActor enum DocsContent {
  struct Section: Identifiable {
    let id: String
    let groups: [DocsModel.Group]
    var title: String {
      let names = [
        "contract": "Contracts", "flow": "Flows", "reference": "References",
        "runbook": "Runbooks", "other": "Other kinds", "none": "Kind not recorded",
      ]
      return (names[id] ?? id) + " · \(groups.count)"
    }
  }

  static func groups(_ entries: [AppDocument]) -> [DocsModel.Group] {
    Dictionary(grouping: entries, by: \.slug).map { DocsModel.Group(id: $0.key, entries: $0.value) }
      .sorted { $0.id < $1.id }
  }

  struct AboutOption {
    let ref: String
    let name: String
  }
  struct AboutSection: Identifiable {
    let title: String
    let options: [AboutOption]
    var id: String { title }
  }

  /// Live apps and services from the map, then topics seen in this workspace's documents.
  static func aboutOptions(map: AppWorkspaceMap?, topics: Set<String>) -> [AboutSection] {
    let sections = [
      AboutSection(
        title: "Apps",
        options: (map?.apps ?? []).map { AboutOption(ref: $0.attachment, name: $0.name) }),
      AboutSection(
        title: "Services",
        options: (map?.services ?? []).map { AboutOption(ref: $0.attachment, name: $0.name) }),
      AboutSection(
        title: "Topics",
        options: topics.sorted().map { AboutOption(ref: $0, name: name($0)) }),
    ]
    return sections.filter { !$0.options.isEmpty }
  }

  /// One section per kind, so a document is listed once however many refs it is about.
  static func sections(_ groups: [DocsModel.Group]) -> [Section] {
    let kinds = ["contract", "flow", "reference", "runbook", "other", "none"]
    func kind(_ group: DocsModel.Group) -> String {
      guard let kind = group.preferred?.kind else { return "none" }
      return kinds.prefix(4).contains(kind) ? kind : "other"
    }
    func name(_ group: DocsModel.Group) -> String { group.preferred?.title ?? group.id }
    let sorted = groups.sorted {
      let order = name($0).localizedStandardCompare(name($1))
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
    let byKind = Dictionary(grouping: sorted, by: kind)
    return kinds.compactMap { id in byKind[id].map { Section(id: id, groups: $0) } }
  }

  /// What the document is about, then its revision state, for the list row.
  static func subtitle(_ group: DocsModel.Group) -> String {
    guard let document = group.preferred else { return "" }
    return
      ([about(document.about)]
      + Array(row(group).split(separator: " · ").dropFirst()).map(String.init))
      .joined(separator: " · ")
  }

  static func about(_ refs: [String]?) -> String {
    guard let refs else { return "Attachments not recorded" }
    if refs.isEmpty { return "Whole workspace" }
    let edges = refs.compactMap(edge)
    if refs.count == 1, let edge = edges.first { return name(edge.0) + " → " + name(edge.1) }
    var apps: [String] = []
    var others: [String] = []
    for ref in refs {
      if let edge = edge(ref) {
        apps += [edge.0, edge.1].filter { !$0.hasPrefix("service:") }.map(name)
      } else if ref.hasPrefix("app:") {
        apps.append(name(ref))
      } else {
        others.append(name(ref))
      }
    }
    apps = apps.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    let head = apps.count > 1 ? ["\(apps.count) apps"] : apps
    return (head + others).joined(separator: " · ")
  }

  /// Splits `edge:source/target/kind` before decoding, so an encoded `/` stays in its part.
  static func edge(_ ref: String) -> (String, String)? {
    guard ref.hasPrefix("edge:") else { return nil }
    let parts = ref.dropFirst(5).split(separator: "/", maxSplits: 2).map(String.init)
    guard parts.count == 3 else { return nil }
    return (parts[0], parts[1])
  }

  /// A readable, decoded name for an attachment ref or a raw edge endpoint.
  static func name(_ ref: String) -> String {
    if let edge = edge(ref) { return name(edge.0) + " → " + name(edge.1) }
    guard let colon = ref.firstIndex(of: ":") else { return ref.removingPercentEncoding ?? ref }
    let kind = ref[..<colon]
    let value = String(ref[ref.index(after: colon)...])
    let decoded = value.removingPercentEncoding ?? value
    return kind == "topic" ? "#" + decoded : decoded
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
