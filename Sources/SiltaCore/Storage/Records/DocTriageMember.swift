import Foundation
import GRDB

/// Literal proposal state and, for acceptance, the current owned projection and map bindings.
struct DocTriageMember {
  let ref: String
  let raw: Row
  let workspaceUID: String
  let baseline: DocEditBaseline?
  let binding: DocVerification.Binding?
  let metadata: DocMetadata?
  let sourceUID: String?

  static func read(_ ref: String, accept: Bool, workspace: Int64, in db: Database) throws -> Self {
    let (slug, revision) = try DocTriage.selection(ref)
    let text = [
      "uid", "body_md", "state", "actor", "message", "created_at", "title", "kind",
      "about_refs", "about_targets", "triaged_at", "triaged_by",
    ]
    let columns = text.map { "CAST(r.\($0) AS BLOB) AS \($0)" }.joined(separator: ",")
    guard
      let raw = try Row.fetchOne(
        db,
        sql: """
          SELECT r.id,r.doc_id,r.rev,r.base_rev,r.source_task_id,CAST(d.uid AS BLOB) AS doc_uid,\(columns)
          FROM doc_rev r JOIN doc d ON d.id=r.doc_id WHERE d.workspace_id=? AND d.slug=? AND r.rev=?
          """, arguments: [workspace, slug, revision])
    else { throw DocError.notFound(ref) }
    guard raw["state"] as Data? == Data("proposed".utf8) else {
      throw DocError.invalid("Only proposed document revisions can be decided.")
    }
    guard
      let workspaceUID = try String.fetchOne(
        db, sql: "SELECT uid FROM workspace WHERE id=?",
        arguments: [workspace])
    else { throw StorageError.corrupt }
    guard accept else {
      return Self(
        ref: ref, raw: raw, workspaceUID: workspaceUID, baseline: nil,
        binding: nil, metadata: nil, sourceUID: nil)
    }
    let baseline = try DocEditBaseline.read(slug, workspace: workspace, keepBody: true, in: db)
    guard baseline.revision == nil || baseline.accepted else { throw StorageError.corrupt }
    guard baseline.revision == raw["base_rev"] as Int? else { throw DocError.stale(ref) }
    let source: Int64? = raw["source_task_id"]
    let sourceUID = try source.map { id in
      guard
        let uid = try String.fetchOne(
          db, sql: "SELECT uid FROM task WHERE id=? AND workspace_id=?",
          arguments: [id, workspace])
      else { throw DocError.changed(workspace: "") }
      return uid
    }
    let value = try DocStore.revision(slug, revision: revision, workspace: workspace, in: db)
    let metadata = try metadata(value, workspace: workspace, in: db)
    return Self(
      ref: ref, raw: raw, workspaceUID: workspaceUID, baseline: baseline,
      binding: try DocVerification.binding(metadata, workspace: workspace, in: db),
      metadata: metadata, sourceUID: sourceUID)
  }

  func same(as other: Self) -> Bool {
    raw == other.raw && workspaceUID == other.workspaceUID && baseline == other.baseline
      && sourceUID == other.sourceUID
  }

  private static func metadata(_ value: DocRevision, workspace: Int64, in db: Database) throws
    -> DocMetadata
  {
    guard let title = value.title, let kind = value.kind, let refs = value.about,
      let targets = value.aboutTargets, !targets.isEmpty, refs.count == targets.count,
      Set(targets).count == targets.count,
      targets.allSatisfy({
        ["app", "edge", "service", "topic"].contains($0.kind)
      }),
      targets.map(\.kind).sorted()
        == refs.compactMap({ ref in
          ref.firstIndex(of: ":").map { String(ref[..<$0]) }
        }).sorted()
    else { throw DocError.changed(workspace: "") }
    let links = try targets.map { target in
      guard
        let id = try Int64.fetchOne(
          db,
          sql: "SELECT id FROM \(target.kind) WHERE workspace_id=? AND uid=?",
          arguments: [workspace, target.uid])
      else { throw DocError.changed(workspace: "") }
      return TaskLinkTarget(kind: target.kind, id: id)
    }
    return try DocMetadata(
      title: title, kind: kind,
      refs: links.map { try $0.rendered(in: db) }, targets: links)
  }
}
