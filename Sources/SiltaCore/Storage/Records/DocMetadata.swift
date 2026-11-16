import Foundation
import GRDB

struct DocMetadata {
  let title: String
  let kind: String
  let refs: [String]
  let targets: [TaskLinkTarget]

  static func resolve(
    _ draft: DocDraft, baseline: DocEditBaseline? = nil, workspace: Int64, in db: Database
  ) throws -> Self {
    let previous = try accepted(draft.slug, baseline: baseline, workspace: workspace, in: db)
    guard WorkspaceConfig.isValidIdentifier(draft.slug) else {
      throw DocError.invalid("Use an identifier for the doc slug.")
    }
    if previous == nil {
      var missing: [String] = []
      if draft.title == nil { missing.append("--title") }
      if draft.about == nil { missing.append("--about") }
      if !missing.isEmpty { throw DocError.missing(missing) }
    }
    let title = draft.title ?? previous?.title ?? ""
    if previous.map({ title.utf8.elementsEqual($0.title.utf8) }) != true {
      try checkTitle(title)
    }
    if let kind = draft.kind, !["contract", "flow", "runbook", "reference"].contains(kind) {
      throw DocError.invalid("Use contract, flow, runbook or reference for --kind.")
    }
    let refs = Array(Set(draft.about ?? previous?.refs ?? [])).sorted()
    guard !refs.isEmpty else {
      if draft.about == nil { throw DocError.missing(["--about"]) }
      throw DocError.invalid("A doc needs at least one --about map item.")
    }
    let targets = try refs.map { try TaskLinkTarget.map($0, workspace: workspace, in: db) }
    return Self(
      title: title,
      kind: draft.kind ?? previous?.kind ?? Self.inferredKind(targets),
      refs: refs, targets: targets)
  }

  static func checkTitle(_ title: String) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DocError.invalid("--title must not be empty.")
    }
    guard title.count <= 120, !title.unicodeScalars.contains(where: CharacterSet.newlines.contains)
    else {
      throw DocError.invalid("--title must be one line of at most 120 characters.")
    }
  }

  private struct Accepted {
    let title: String
    let kind: String
    let refs: [String]
  }

  private static func accepted(
    _ slug: String, baseline: DocEditBaseline?, workspace: Int64, in db: Database
  ) throws -> Accepted? {
    if let baseline {
      guard baseline.revision != nil else { return nil }
      guard baseline.accepted, let title = baseline.title, let kind = baseline.kind else {
        throw StorageError.corrupt
      }
      return Accepted(title: title, kind: kind, refs: baseline.refs)
    }
    let old = try Row.fetchOne(
      db,
      sql: """
        SELECT d.*,CAST(d.title AS BLOB) AS title_bytes,CAST(d.kind AS BLOB) AS kind_bytes,
          r.state AS revision_state FROM doc d
        LEFT JOIN doc_rev r ON r.doc_id=d.id AND r.rev=d.current_rev
        WHERE d.workspace_id=? AND d.slug=?
        """, arguments: [workspace, slug])
    guard let old, (old["current_rev"] as Int?) != nil else { return nil }
    guard old["revision_state"] as String? == "accepted" else { throw StorageError.corrupt }
    guard let title = try old.strictText("title_bytes"), let kind = try old.strictText("kind_bytes")
    else { throw StorageError.corrupt }
    return Accepted(
      title: title, kind: kind,
      refs: try DocStore.attachments(old["id"], workspace: workspace, in: db).map {
        try TaskLinkTarget.render($0, in: db)
      })
  }

  private static func inferredKind(_ targets: [TaskLinkTarget]) -> String {
    let edges = targets.filter { $0.kind == "edge" }.count
    if edges > 1 { return "flow" }
    if edges == 1 { return "contract" }
    return targets.contains { $0.kind == "service" } ? "runbook" : "reference"
  }
}
