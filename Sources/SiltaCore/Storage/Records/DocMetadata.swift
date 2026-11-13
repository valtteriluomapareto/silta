import Foundation
import GRDB

struct DocMetadata {
  let title: String
  let kind: String
  let refs: [String]
  let targets: [TaskLinkTarget]

  static func resolve(_ draft: DocDraft, workspace: Int64, in db: Database) throws -> Self {
    let old = try Row.fetchOne(
      db, sql: "SELECT * FROM doc WHERE workspace_id=? AND slug=?",
      arguments: [workspace, draft.slug])
    guard WorkspaceConfig.isValidIdentifier(draft.slug) else {
      throw DocError.invalid("Use an identifier for the doc slug.")
    }
    let accepted = try hasAcceptedRevision(old, in: db)
    if !accepted {
      var missing: [String] = []
      if draft.title == nil { missing.append("--title") }
      if draft.about == nil { missing.append("--about") }
      if !missing.isEmpty { throw DocError.missing(missing) }
    }
    let previousTitle: String? = old?["title"]
    let title = draft.title ?? previousTitle ?? ""
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DocError.invalid("--title must not be empty.")
    }
    guard title.count <= 120, !title.unicodeScalars.contains(where: CharacterSet.newlines.contains)
    else {
      throw DocError.invalid("--title must be one line of at most 120 characters.")
    }
    if let kind = draft.kind, !["contract", "flow", "runbook", "reference"].contains(kind) {
      throw DocError.invalid("Use contract, flow, runbook or reference for --kind.")
    }
    let previous =
      try old.map {
        try DocStore.attachments($0["id"], workspace: workspace, in: db).map {
          try TaskLinkTarget.render($0, in: db)
        }
      } ?? []
    let refs = Array(Set(draft.about ?? previous)).sorted()
    guard !refs.isEmpty else {
      throw DocError.invalid("A doc needs at least one --about map item.")
    }
    let targets = try refs.map { try TaskLinkTarget.map($0, workspace: workspace, in: db) }
    let previousKind: String? = accepted ? old?["kind"] : nil
    return Self(
      title: title, kind: draft.kind ?? previousKind ?? Self.inferredKind(targets),
      refs: refs, targets: targets)
  }

  private static func hasAcceptedRevision(_ old: Row?, in db: Database) throws -> Bool {
    guard let old, let revision: Int = old["current_rev"] else { return false }
    guard
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(SELECT 1 FROM doc_rev WHERE doc_id=? AND rev=? AND state='accepted')
          """, arguments: [old["id"], revision]) == true
    else { throw StorageError.corrupt }
    return true
  }

  private static func inferredKind(_ targets: [TaskLinkTarget]) -> String {
    let edges = targets.filter { $0.kind == "edge" }.count
    if edges > 1 { return "flow" }
    if edges == 1 { return "contract" }
    return targets.contains { $0.kind == "service" } ? "runbook" : "reference"
  }
}
